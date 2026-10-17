"""Local monitor and explicit controls through a private loopback bridge."""
from __future__ import annotations

import argparse
from collections import deque
import json
import os
from pathlib import Path
import signal
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import urllib.request

from .monitoring import INTERVAL_SECONDS, MAX_SNAPSHOT_BYTES, window_at_least

try:
    import psutil
except ImportError:
    psutil = None

ASSETS = Path(__file__).with_name("dashboard_assets")
STALE_SECONDS = 8


class Collector:
    def __init__(self, state_dir: Path) -> None:
        self.path = state_dir / "monitor.json"
        self.control_path = state_dir / "control.json"
        self.sample_lock = threading.RLock()
        self.expected_window = None
        self.window_id = None
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._loop, name="dashboard-sampler", daemon=True)
        self.last_runtime = None
        self.processes = {}
        self.history = deque(maxlen=90)
        self.value = {"connection": "starting", "runtime": None, "host": None, "processes": {}}
        self.boot_id = None
        self.restarts_observed = 0
        self.started_at = time.time()
        if psutil:
            psutil.cpu_percent(interval=None)

    def start(self) -> None:
        self.thread.start()

    def close(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=3)

    def _process(self, name, pid, before=None):
        if not psutil or not pid:
            self.processes.pop(name, None)
            return None
        try:
            process = self.processes.get(name)
            fresh = process is None or process.pid != pid
            if fresh:
                process = psutil.Process(pid)
                self.processes[name] = process
            if not process.is_running() or (before is not None and process.create_time() > before):
                self.processes.pop(name, None)
                return None
            return {"pid": pid, "rss_bytes": process.memory_info().rss,
                    "cpu_percent": None if fresh else process.cpu_percent(interval=None),
                    "cpu_warming_up": fresh}
        except (psutil.Error, OSError):
            self.processes.pop(name, None)
            return None
        finally:
            if fresh and name in self.processes:
                try:
                    self.processes[name].cpu_percent(interval=None)
                except psutil.Error:
                    pass

    def sample(self) -> dict:
        with self.sample_lock:
            return self._sample()

    def reset_history(self, window_id, boot_id, sequence, generation):
        with self.sample_lock:
            self.history.clear()
            self.restarts_observed = 0
            self.last_runtime = None
            reset_window = {"window_id": window_id, "boot_id": boot_id,
                            "window_sequence": sequence, "producer_generation": generation}
            if window_at_least(reset_window, self.expected_window):
                self.expected_window = reset_window
            self.sample()

    def _sample(self) -> dict:
        started = time.monotonic()
        now = time.time()
        connection = "disconnected"
        try:
            with self.path.open("rb") as handle:
                raw = handle.read(MAX_SNAPSHOT_BYTES + 1)
            if len(raw) > MAX_SNAPSHOT_BYTES:
                raise ValueError("oversize snapshot")
            runtime = json.loads(raw)
            if runtime.get("schema_version") != 1 or not isinstance(runtime.get("sampled_at"), (int, float)):
                raise ValueError("unsupported snapshot")
            if not window_at_least(runtime, self.expected_window):
                raise ValueError("waiting for reset snapshot")
            # Retain the high-water mark even after the first matching export.
            self.expected_window = {key: runtime.get(key, 0) for key in
                                    ("boot_id", "window_id", "window_sequence", "producer_generation")}
            if runtime.get("window_id") != self.window_id:
                self.history.clear()
                self.window_id = runtime.get("window_id")
            age = now - runtime["sampled_at"]
            connection = "live" if -2 <= age <= STALE_SECONDS else "stale"
            if self.boot_id and self.boot_id != runtime["boot_id"]:
                self.restarts_observed += 1
            self.boot_id = runtime["boot_id"]
            self.last_runtime = runtime
        except (OSError, ValueError, KeyError, TypeError):
            pass
        runtime = self.last_runtime
        processes = {"dashboard": self._process("dashboard", os.getpid())}
        if runtime:
            processes["runtime"] = self._process("runtime", runtime["runtime_pid"], runtime["started_at"])
            if psutil and processes["runtime"] is None:
                connection = "disconnected"
            processes["model"] = self._process("model", runtime["model_process"].get("pid"), runtime["sampled_at"])
        host = None
        if psutil:
            try:
                memory = psutil.virtual_memory()
                host = {"cpu_percent": psutil.cpu_percent(interval=None), "logical_cpus": psutil.cpu_count(),
                        "ram_total_bytes": memory.total, "ram_available_bytes": memory.available,
                        "ram_used_bytes": memory.total - memory.available,
                        "swap_used_bytes": psutil.swap_memory().used}
            except (psutil.Error, OSError):
                pass
        if host:
            self.history.append({"at": now, "cpu_percent": host["cpu_percent"], "ram_used_bytes": host["ram_used_bytes"]})
        value = {"sampled_at": now, "connection": connection, "stale_after_seconds": STALE_SECONDS,
                 "runtime": runtime, "host": host, "processes": processes,
                 "resource_metrics_available": psutil is not None,
                 "history": list(self.history), "history_capacity": self.history.maxlen,
                 "restarts_observed": self.restarts_observed, "dashboard_started_at": self.started_at,
                 "sample_interval_seconds": INTERVAL_SECONDS,
                 "sample_duration_ms": round((time.monotonic() - started) * 1000, 2)}
        with self.lock:
            self.value = value
        return value

    def snapshot(self) -> dict:
        with self.lock:
            return dict(self.value)

    def memory_observation(self, pid=None):
        if not psutil:
            return {"at": time.time(), "available": False}
        try:
            memory = psutil.virtual_memory()
            process = psutil.Process(pid) if pid and psutil.pid_exists(pid) else None
            return {"at": time.time(), "available": True, "host_used_bytes": memory.total - memory.available,
                    "model_pid": pid, "model_process_exists": bool(process),
                    "model_rss_bytes": process.memory_info().rss if process else None}
        except (psutil.Error, OSError):
            return {"at": time.time(), "available": False}

    def _loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                self.sample()
            except Exception:
                # A failed sampler must make freshness visibly fail, never kill the website.
                with self.lock:
                    self.value = dict(self.value, connection="disconnected")
            self.stop_event.wait(INTERVAL_SECONDS)


class DashboardHandler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(2)

    def log_message(self, *_args):
        pass

    def do_POST(self):
        host = self.headers.get("Host")
        hosts = {"127.0.0.1:%d" % self.server.server_port, "localhost:%d" % self.server.server_port}
        if (self.client_address[0] != "127.0.0.1" or host not in hosts
                or self.headers.get("Origin") != "http://" + host
                or self.headers.get("Sec-Fetch-Site") not in {None, "same-origin"}
                or self.headers.get("Content-Type") != "application/json"
                or not secrets.compare_digest(self.headers.get("X-Dashboard-Token", ""), self.server.token)):
            self.send_error(403)
            return
        if self.path != "/api/control":
            self.send_error(404)
            return
        if not self.server.control_lock.acquire(blocking=False):
            self._reply(409, {"ok": False, "message": "Another control is running. Wait for its result."})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 2048:
                raise ValueError()
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError()
            collector = self.server.collector
            snapshot = collector.snapshot()
            pid = (snapshot.get("runtime") or {}).get("model_process", {}).get("pid")
            before = collector.memory_observation(pid)
            connection = json.loads(collector.control_path.read_text())
            request = urllib.request.Request("http://127.0.0.1:%d/control" % connection["port"],
                data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + connection["token"], "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.load(response)
            if body.get("action") == "reset" and result.get("ok"):
                collector.reset_history(result["window_id"], result["boot_id"], result["window_sequence"], result["producer_generation"])
            result.update({"before": before, "after": collector.memory_observation(result.get("model_pid", pid))})
            self._reply(200, result)
        except (OSError, ValueError, KeyError, TypeError):
            self._reply(503, {"ok": False, "message": "Runtime control unavailable or timed out. Outcome is unknown; inspect the live state before retrying. The dashboard remains available."})
        finally:
            self.server.control_lock.release()

    def _reply(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(raw)
        except OSError:
            pass

    def do_GET(self):
        port = self.server.server_port
        hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}
        origin = self.headers.get("Origin")
        path = urlsplit(self.path).path
        top_level_page = (path == "/" and self.headers.get("Sec-Fetch-Mode") == "navigate"
                          and self.headers.get("Sec-Fetch-Dest") == "document")
        if (self.client_address[0] != "127.0.0.1" or self.headers.get("Host") not in hosts
                or (origin and origin not in {"http://" + h for h in hosts})
                or (self.headers.get("Sec-Fetch-Site") == "cross-site" and not top_level_page)):
            self.send_error(403)
            return
        if path == "/api/monitor":
            raw = json.dumps(dict(self.server.collector.snapshot(), control_token=self.server.token), separators=(",", ":"), allow_nan=False).encode()
            mime = "application/json"
        elif path in {"/", "/dashboard.css", "/dashboard.js"}:
            asset = "index.html" if path == "/" else path[1:]
            raw = (ASSETS / asset).read_bytes()
            mime = {"/": "text/html; charset=utf-8", "/dashboard.css": "text/css", "/dashboard.js": "text/javascript"}[path]
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass


class DashboardServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self, port, collector):
        # Never accept a configurable interface or expose telemetry on the phone listener.
        super().__init__(("127.0.0.1", port), DashboardHandler)
        self.collector = collector
        self.token = secrets.token_urlsafe(32)
        self.control_lock = threading.Lock()


def run():
    parser = argparse.ArgumentParser(description="Muse Glimmer localhost monitor")
    parser.add_argument("--state-dir", type=Path, default=Path(__file__).resolve().parents[1] / "state")
    parser.add_argument("--port", type=int, default=11436)
    args = parser.parse_args()
    collector = Collector(args.state_dir)
    server = DashboardServer(args.port, collector)
    def stop(*_args):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    collector.start()
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        collector.close()


if __name__ == "__main__":
    run()
