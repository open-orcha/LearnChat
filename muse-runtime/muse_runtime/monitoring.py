"""Bounded, private telemetry export. No inference or lease activity is initiated here."""
from __future__ import annotations

import json
import fcntl
import logging
import os
import threading
from typing import Any


LOG = logging.getLogger("muse_runtime.monitoring")
INTERVAL_SECONDS = 2
MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024


def next_generation(state_dir):
    """Order producers across restarts, independently of wall-clock changes.

    Keep the lock inode stable and replace the private counter atomically. A failed
    allocation stops startup rather than issuing an ambiguous producer order.
    """
    path = state_dir / "monitor-generation"
    fd = os.open(str(path.with_suffix(".lock")), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        generation = int(path.read_text()) + 1 if path.exists() else 1
        temporary = path.with_suffix(".tmp")
        fd = os.open(str(temporary), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(str(generation))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        return generation


def window_at_least(candidate, floor):
    """An unrelated boot ID alone is never evidence of a newer producer."""
    if not floor:
        return True
    generation = candidate.get("producer_generation", 0)
    minimum = floor.get("producer_generation", 0)
    if generation != minimum:
        return generation > minimum
    if candidate.get("boot_id") != floor.get("boot_id"):
        return False
    sequence = candidate.get("window_sequence", 0)
    threshold = floor.get("window_sequence", 0)
    return sequence > threshold or (sequence == threshold and candidate.get("window_id") == floor.get("window_id"))


class TelemetryExporter:
    def __init__(self, runtime: Any) -> None:
        self.runtime = runtime
        self.path = runtime.config.state_dir / "monitor.json"
        self.generation = next_generation(runtime.config.state_dir)
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._loop, name="monitor-export", daemon=True)
        self.last_ready = None

    def start(self) -> None:
        self.thread.start()

    def close(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=3)

    def snapshot(self) -> dict:
        runtime, cfg = self.runtime, self.runtime.config
        # health/status are observational: never ensure_running or note_activity.
        model = runtime.supervisor.status()
        ready = model["loaded"]
        if ready != self.last_ready:
            runtime.manager.record_event("backend_ready" if ready else "backend_unavailable")
            self.last_ready = ready
        data = runtime.manager.monitor_snapshot()
        data.update({
            "schema_version": 1, "runtime_pid": os.getpid(),
            "producer_generation": self.generation,
            "ready": ready, "model": cfg.model_name[:128], "model_process": model,
            "recovery_required": bool(getattr(runtime, "recovery_required", False)),
            "limits": {
                "lease_seconds": cfg.lease_seconds,
                "session_tokens": cfg.session_token_limit,
                "total_cache_tokens": cfg.total_cache_token_limit,
                "context_tokens": cfg.context_size, "slot_context_tokens": cfg.slot_context_size,
                "slots": cfg.slots, "max_output_tokens": cfg.max_output_tokens,
                "snapshot_mode": cfg.snapshot_mode,
                "model_unload_policy": cfg.model_unload_policy,
                "model_idle_seconds": cfg.model_idle_seconds,
                "ram_eviction_bytes": None,
            },
        })
        return data

    def write_once(self) -> None:
        raw = json.dumps(self.snapshot(), separators=(",", ":"), allow_nan=False).encode()
        if len(raw) > MAX_SNAPSHOT_BYTES:
            raise ValueError("monitor snapshot exceeds size bound")
        # Atomic replacement means readers never see a partially written snapshot.
        # Both the temporary and final file are private to the current user.
        temporary = self.path.with_suffix(".tmp")
        fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(raw)
        os.replace(temporary, self.path)

    def _loop(self) -> None:
        warned = False
        while not self.stop_event.is_set():
            try:
                self.write_once()
                warned = False
            except Exception:
                # Telemetry failures must not stop inference or leak exception text.
                if not warned:
                    LOG.warning("monitor export unavailable; dashboard will report stale data")
                    warned = True
            self.stop_event.wait(INTERVAL_SECONDS)
