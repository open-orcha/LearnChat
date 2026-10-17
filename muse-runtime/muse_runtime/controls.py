"""Private authenticated loopback bridge; never mounted on the phone listener."""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import secrets
import threading

from .backend import BackendError
from .core import SessionBusy, SessionNotFound


class ControlServer:
    def __init__(self, runtime):
        self.runtime = runtime
        self.token = secrets.token_urlsafe(32)
        self.operation_lock = threading.Lock()
        self.unload_complete = False
        self.path = runtime.config.state_dir / "control.json"
        self.server = None

    def start(self):
        control = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                self.connection.settimeout(2)
                if (self.path != "/control" or self.client_address[0] != "127.0.0.1"
                        or self.headers.get("Origin")
                        or not secrets.compare_digest(self.headers.get("Authorization", ""), "Bearer " + control.token)):
                    self.send_error(403)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= 2048:
                        raise ValueError()
                    body = json.loads(self.rfile.read(length))
                    result = control.execute(body)
                except (ValueError, TypeError, OSError):
                    result = {"ok": False, "message": "Invalid control request."}
                raw = json.dumps(result).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                try:
                    self.wfile.write(raw)
                except OSError:
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        fd = os.open(str(self.path), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump({"port": self.server.server_port, "token": self.token}, handle)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.path.unlink(missing_ok=True)

    def execute(self, body):
        if not isinstance(body, dict) or body.get("action") not in {"reset", "evict", "unload", "reload"}:
            return {"ok": False, "message": "Unknown control action."}
        if not self.operation_lock.acquire(blocking=False):
            return {"ok": False, "message": "Another control is running. Wait for its result."}
        runtime, manager = self.runtime, self.runtime.manager
        action = body["action"]
        try:
            if action == "unload":
                previous_recovery_required = runtime.recovery_required
                self.unload_complete = False
                manager.admission_paused.set()
                # Stop first: a hung backend call may own the manager lock.
                with runtime.admission_lock:
                    runtime.recovery_required = True
                    for handler in list(runtime.active_handlers):
                        handler.cancel()
                    with runtime.supervisor.lock:
                        process = runtime.supervisor.process
                        was_running = process is not None and process.poll() is None
                        stopped = runtime.supervisor.pause_and_stop()
                    if not stopped:
                        # Pausing an empty/unmanaged backend is not an erase failure.
                        # Keep a real pre-existing quarantine, but do not invent one
                        # that permanently prevents explicit reload after idle unload
                        # or a persisted pause. No health probe is needed to decide.
                        runtime.recovery_required = previous_recovery_required
                        next_step = ("Previous recovery is still required; stop the externally managed backend before resuming."
                                     if previous_recovery_required else "Chats remain paused; explicit Reload model is available.")
                        return {"ok": False, "message": "No supervised backend process to stop. No memory release is claimed; an externally managed backend cannot be released here. " + next_step}
                if not manager.lock.acquire(timeout=3):
                    return {"ok": False, "message": "Backend stopped and remains paused, but cache bookkeeping is still busy. Retry unload before reloading."}
                try:
                    manager.backend_unloaded()
                    self.unload_complete = True
                finally:
                    manager.lock.release()
                message = ("Supervised backend stopped and paused. All its chats were interrupted and model weights unloaded."
                           if was_running else "Backend already stopped and remains paused. No additional memory release is claimed.")
                result = {"ok": True, "message": message + " Phone history is preserved. Use Reload model to resume."}
            elif action == "reload":
                with runtime.admission_lock:
                    if runtime.active_requests:
                        return {"ok": False, "message": "Interrupted requests are still draining. Wait and retry reload."}
                    if runtime.recovery_required and not self.unload_complete:
                        return {"ok": False, "message": "Unload and pause the backend before reloading after an erase failure."}
                runtime.supervisor.reload()
                runtime.recovery_required = False
                manager.admission_paused.clear()
                result = {"ok": True, "message": "Model reloaded. Chats can resume and rebuild from phone history."}
            else:
                if not manager.lock.acquire(timeout=2):
                    return {"ok": False, "message": "Runtime is busy. Retry, or use unload and pause for a stuck backend."}
                try:
                    if action == "reset":
                        manager.reset_monitoring()
                        result = {"ok": True, "message": "Dashboard history and displayed totals reset. Chats, leases, inference and limits are unchanged.", "window_id": manager.window_id,
                                  "boot_id": manager.monitor_id, "window_sequence": manager.window_sequence,
                                  "producer_generation": runtime.telemetry.generation}
                    else:
                        target = body.get("target")
                        if not isinstance(target, str) or not target:
                            raise ValueError("Choose a conversation or all caches.")
                        with runtime.admission_lock:
                            if runtime.active_requests:
                                raise SessionBusy("A chat request is active. Wait, or use unload and pause to interrupt all chats.")
                            if runtime.supervisor.paused or runtime.recovery_required:
                                raise ValueError("Backend is paused or needs recovery. Use unload/reload first.")
                            result = manager.force_evict(target)
                            if not result["ok"]:
                                runtime.recovery_required = True
                                manager.admission_paused.set()
                                result["message"] += " New chats are blocked until unload/reload, because an erase may still be pending."
                finally:
                    manager.lock.release()
            process = runtime.supervisor.process
            result["model_pid"] = process.pid if process is not None and process.poll() is None else None
            return result
        except SessionNotFound:
            return {"ok": False, "message": "Conversation no longer exists. Refresh and choose another target."}
        except (SessionBusy, ValueError, BackendError) as exc:
            # Only the backend's public lifecycle errors are surfaced, never prompts.
            return {"ok": False, "message": str(exc)[:300]}
        except Exception:
            return {"ok": False, "message": "Control failed. The backend may need unload/reload; no success is assumed."}
        finally:
            self.operation_lock.release()
