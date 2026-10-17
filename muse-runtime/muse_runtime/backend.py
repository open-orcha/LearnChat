from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

from .config import Config


LOG = logging.getLogger("muse_runtime.backend")


class BackendError(RuntimeError):
    pass


class HttpLlamaBackend:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.base_url = config.backend_url
        self.health_lock = threading.Lock()

    def _request(
        self,
        path: str,
        payload: Optional[Dict[str, Any]] = None,
        timeout: float = 30.0,
    ) -> Dict[str, Any]:
        data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            headers={"Content-Type": "application/json"} if data is not None else {},
            method="POST" if data is not None else "GET",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
        except (urllib.error.URLError, TimeoutError) as exc:
            raise BackendError("llama.cpp request failed: %s" % exc) from exc
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError as exc:
            raise BackendError("llama.cpp returned invalid JSON") from exc

    def health(self) -> bool:
        # At most one outstanding probe; trickled bytes must not block callers
        # or create an unbounded pile of health workers.
        if not self.health_lock.acquire(blocking=False):
            return False
        done = threading.Event()
        outcome = []
        def probe():
            try:
                result = self._request("/health", timeout=2.0)
                outcome.append(result.get("status") in {"ok", "no slot available"})
            except Exception:
                outcome.append(False)
            finally:
                self.health_lock.release()
                done.set()
        threading.Thread(target=probe, daemon=True).start()
        return bool(done.wait(2.5) and outcome and outcome[0])

    def count_tokens(self, messages: List[Dict[str, Any]]) -> int:
        result = self._request(
            "/v1/chat/completions/input_tokens",
            {"model": self.config.model_name, "messages": messages},
            timeout=15.0,
        )
        return int(result.get("input_tokens", 0))

    def stream_chat(self, payload: Dict[str, Any]) -> Iterator[Dict[str, Any]]:
        request = urllib.request.Request(
            self.base_url + "/v1/chat/completions",
            data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=3600.0) as response:
                for raw_line in response:
                    line = raw_line.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if not data or data == "[DONE]":
                        continue
                    yield json.loads(data)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:500]
            raise BackendError("llama.cpp HTTP %d: %s" % (exc.code, detail)) from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise BackendError("llama.cpp streaming request failed: %s" % exc) from exc

    def erase_slot(self, slot_id: int) -> bool:
        return self._slot_action(slot_id, "erase", timeout=3.0)

    def save_slot(self, slot_id: int, filename: str) -> bool:
        return self._slot_action(slot_id, "save", filename)

    def restore_slot(self, slot_id: int, filename: str) -> bool:
        return self._slot_action(slot_id, "restore", filename)

    def _slot_action(self, slot_id: int, action: str, filename: Optional[str] = None, timeout: float = 15.0) -> bool:
        payload: Dict[str, Any] = {}
        if filename:
            payload["filename"] = filename
        path = "/slots/%d?action=%s" % (slot_id, urllib.parse.quote(action))
        try:
            result = self._request(path, payload, timeout=timeout)
            return "error" not in result
        except BackendError:
            LOG.warning("slot %s failed for slot %d", action, slot_id)
            return False

    def delete_snapshot(self, filename: str) -> None:
        safe_name = Path(filename).name
        path = self.config.state_dir / "slots" / safe_name
        try:
            path.unlink(missing_ok=True)
        except OSError:
            LOG.warning("could not delete slot snapshot %s", safe_name)

    def slots(self) -> List[Dict[str, Any]]:
        result = self._request("/slots", timeout=5.0)
        return result if isinstance(result, list) else []


class ModelSupervisor:
    def __init__(self, config: Config, backend: HttpLlamaBackend) -> None:
        self.config = config
        self.backend = backend
        self.process: Optional[subprocess.Popen[Any]] = None
        self.lock = threading.RLock()
        self.last_active_at = time.time()
        self.started_at: Optional[float] = None
        self.log_handle: Optional[Any] = None
        self.pause_path = config.state_dir / "backend-paused"
        self.paused = self.pause_path.exists()
        self.manually_stopped = False

    def ensure_running(self, wait_seconds: int = 180) -> None:
        observed_process = self.process
        healthy = self.backend.health()
        with self.lock:
            if self.paused:
                raise BackendError("Model is manually paused. Reload it from the local dashboard.")
            self.last_active_at = time.time()
            if healthy and self.process is observed_process:
                return
            if not self.config.backend_autostart:
                raise BackendError("llama.cpp backend is unavailable and autostart is disabled")
            if self.process is not None and self.process.poll() is None:
                pass
            else:
                self._start()
        # Never hold the supervisor lock while waiting for a stuck startup.
        self._wait_healthy(wait_seconds)

    def note_activity(self) -> None:
        with self.lock:
            self.last_active_at = time.time()

    def maybe_unload(self, active_leases: int) -> bool:
        with self.lock:
            if active_leases > 0 or self.process is None or self.process.poll() is not None:
                return False
            policy = self.config.model_unload_policy
            idle = time.time() - self.last_active_at
            if policy == "immediate" or (policy == "idle_timeout" and idle >= self.config.model_idle_seconds):
                self.stop()
                return True
            return False

    def stop(self) -> None:
        with self.lock:
            process = self.process
            if process is not None and process.poll() is None:
                LOG.info("stopping llama.cpp model process")
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            self.process = None
            if self.log_handle is not None:
                self.log_handle.close()
                self.log_handle = None

    def pause_and_stop(self) -> bool:
        with self.lock:
            # Persist intent before stopping, including across runtime restarts.
            self.pause_path.touch(mode=0o600)
            self.paused = True
            if self.process is None:
                return self.manually_stopped
            self.stop()
            self.manually_stopped = True
            return True

    def reload(self) -> None:
        with self.lock:
            self.paused = False
            self.pause_path.unlink(missing_ok=True)
        try:
            self.ensure_running(wait_seconds=45)
            self.manually_stopped = False
        except Exception:
            self.pause_and_stop()
            raise

    def status(self) -> Dict[str, Any]:
        observed_process = self.process
        running = self.backend.health()
        with self.lock:
            running = running and not self.paused and self.process is observed_process
            return {
                "loaded": running,
                "pid": self.process.pid if self.process is not None and self.process.poll() is None else None,
                "uptime_seconds": int(time.time() - self.started_at) if running and self.started_at else None,
                "unload_policy": self.config.model_unload_policy,
                "paused": self.paused,
            }

    def _start(self) -> None:
        self.config.state_dir.mkdir(parents=True, exist_ok=True)
        slot_dir = self.config.state_dir / "slots"
        slot_dir.mkdir(parents=True, exist_ok=True)
        log_path = self.config.state_dir / "llama-server.log"
        self.log_handle = open(log_path, "a", buffering=1)
        args = [
            self.config.llama_binary,
            "--model",
            str(self.config.model_path),
            "--mmproj",
            str(self.config.mmproj_path),
            "--host",
            self.config.backend_host,
            "--port",
            str(self.config.backend_port),
            "--ctx-size",
            str(self.config.context_size),
            "--parallel",
            str(self.config.slots),
            "--kv-unified-per-slot",
            str(self.config.slot_context_size),
            "--flash-attn",
            "on",
            "--cache-prompt",
            "--slots",
            "--metrics",
            "--slot-save-path",
            str(slot_dir),
            "--no-context-shift",
            "--no-webui",
        ]
        LOG.info("starting llama.cpp with %d slots and %d-token total context", self.config.slots, self.config.context_size)
        self.process = subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=self.log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=os.environ.copy(),
        )
        self.started_at = time.time()

    def _wait_healthy(self, wait_seconds: int) -> None:
        deadline = time.monotonic() + wait_seconds
        while time.monotonic() < deadline:
            if self.paused:
                raise BackendError("Model loading was interrupted by manual pause.")
            if self.backend.health():
                LOG.info("llama.cpp model is ready")
                return
            if self.process is not None and self.process.poll() is not None:
                raise BackendError("llama.cpp exited during startup; see %s" % (self.config.state_dir / "llama-server.log"))
            time.sleep(0.5)
        raise BackendError("llama.cpp did not become ready within %d seconds" % wait_seconds)
