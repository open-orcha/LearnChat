from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import secrets
import signal
import socket
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse

from .backend import BackendError, HttpLlamaBackend, ModelSupervisor
from .monitoring import TelemetryExporter
from .controls import ControlServer
from .config import Config
from .core import (
    CacheUnavailable,
    ContextTooLarge,
    NoSlotAvailable,
    SessionBusy,
    SessionManager,
    SessionNotFound,
    derive_session_id,
    estimate_message_tokens,
)


LOG = logging.getLogger("muse_runtime")


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _load_or_create_secret(state_dir: Path) -> bytes:
    state_dir.mkdir(parents=True, exist_ok=True)
    path = state_dir / "session-secret"
    if path.exists():
        return path.read_bytes()
    secret = secrets.token_bytes(32)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(str(path), flags, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(secret)
    return secret


def ollama_to_openai(messages: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    converted: List[Dict[str, Any]] = []
    for message in messages:
        item: Dict[str, Any] = {"role": message.get("role", "user")}
        content = message.get("content", "")
        images = message.get("images") or []
        if images:
            parts: List[Dict[str, Any]] = []
            if content:
                parts.append({"type": "text", "text": str(content)})
            for encoded in images:
                raw = str(encoded)
                if raw.startswith("data:"):
                    url = raw
                else:
                    try:
                        head = base64.b64decode(raw[:64] + "===", validate=False)[:12]
                    except Exception:
                        head = b""
                    mime = "image/png" if head.startswith(b"\x89PNG") else "image/jpeg"
                    url = "data:%s;base64,%s" % (mime, raw)
                parts.append({"type": "image_url", "image_url": {"url": url}})
            item["content"] = parts
        else:
            item["content"] = content
        thinking = message.get("thinking")
        if thinking:
            item["reasoning_content"] = thinking
        converted.append(item)
    return converted


def ollama_done_reason(finish_reason: Optional[str]) -> str:
    if finish_reason in {"length", "max_tokens"}:
        return "length"
    if finish_reason in {"stop", "eos_token", None, ""}:
        return "stop"
    return str(finish_reason)


class Runtime:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.backend = HttpLlamaBackend(config)
        self.supervisor = ModelSupervisor(config, self.backend)
        self.manager = SessionManager(
            self.backend,
            slots=config.slots,
            lease_seconds=config.lease_seconds,
            session_token_limit=config.session_token_limit,
            total_cache_token_limit=config.total_cache_token_limit,
            snapshot_mode=config.snapshot_mode,
        )
        self.secret = _load_or_create_secret(config.state_dir)
        self.telemetry = TelemetryExporter(self)
        self.admission_lock = threading.Lock()
        self.active_requests = 0
        self.active_handlers = set()
        self.recovery_required = False
        self.controls = ControlServer(self)
        if self.supervisor.paused:
            self.manager.admission_paused.set()
        self.stop_event = threading.Event()
        self.reaper = threading.Thread(target=self._reaper_loop, name="lease-reaper", daemon=True)

    def start(self) -> None:
        if self.config.backend_autostart and not self.supervisor.paused:
            self.supervisor.ensure_running()
        self.controls.start()
        self.reaper.start()
        self.telemetry.start()

    def close(self) -> None:
        self.stop_event.set()
        self.controls.close()
        self.telemetry.close()
        self.supervisor.stop()

    def _reaper_loop(self) -> None:
        while not self.stop_event.wait(1.0):
            self.manager.reap_expired()
            self.supervisor.maybe_unload(self.manager.active_lease_count())

    def status(self) -> Dict[str, Any]:
        result = self.manager.status()
        result.update(
            {
                "service": "muse-glimmer-runtime",
                "ready": self.backend.health(),
                "model": self.config.model_name,
                "model_process": self.supervisor.status(),
                "lease_seconds": self.config.lease_seconds,
                "session_token_limit": self.config.session_token_limit,
                "total_cache_token_limit": self.config.total_cache_token_limit,
                "slots": self.config.slots,
                "snapshot_mode": self.config.snapshot_mode,
                "content_logging": False,
            }
        )
        return result


class MuseHandler(BaseHTTPRequestHandler):
    server_version = "MuseGlimmerRuntime/0.1"
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def cancel(self):
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    @property
    def runtime(self) -> Runtime:
        return self.server.runtime  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:
        # Deliberately avoid standard access logs: URL/query data can contain identifiers.
        return

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/healthz":
            status = self.runtime.status()
            self._json(HTTPStatus.OK if status["ready"] else HTTPStatus.SERVICE_UNAVAILABLE, {"status": "ok" if status["ready"] else "loading"})
        elif path == "/api/tags":
            self._json(
                HTTPStatus.OK,
                {
                    "models": [
                        {
                            "name": self.runtime.config.model_name,
                            "model": self.runtime.config.model_name,
                            "modified_at": _iso_now(),
                            "size": self.runtime.config.model_path.stat().st_size,
                            "digest": self.runtime.config.model_path.name.removeprefix("sha256-"),
                        }
                    ]
                },
            )
        elif path == "/api/status":
            if not self._authorized():
                return
            self._json(HTTPStatus.OK, self.runtime.status())
        elif path == "/metrics":
            if not self._authorized():
                return
            self._metrics()
        else:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/chat":
            if self._authorized():
                self._chat()
            return
        if path.startswith("/api/sessions/") and path.endswith("/heartbeat"):
            if self._authorized():
                session_id = path[len("/api/sessions/") : -len("/heartbeat")].strip("/")
                self._heartbeat(session_id)
            return
        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        if path.startswith("/api/sessions/"):
            if not self._authorized():
                return
            session_id = path[len("/api/sessions/") :].strip("/")
            try:
                released = self.runtime.manager.release(session_id)
                self._json(HTTPStatus.OK if released else HTTPStatus.NOT_FOUND, {"released": released})
            except SessionBusy:
                self._json(HTTPStatus.CONFLICT, {"error": "session has an active request"})
            return
        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def _authorized(self) -> bool:
        expected = self.runtime.config.api_key
        if not expected:
            return True
        supplied = self.headers.get("Authorization", "")
        if secrets.compare_digest(supplied, "Bearer " + expected):
            return True
        self._json(HTTPStatus.UNAUTHORIZED, {"error": "missing or invalid API key"})
        return False

    def _read_json(self) -> Dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if length <= 0 or length > 64 * 1024 * 1024:
            raise ValueError("request body must be between 1 byte and 64 MiB")
        try:
            # Bound the whole upload, not just gaps between incoming bytes.
            deadline = threading.Timer(10, self.cancel)
            deadline.daemon = True
            deadline.start()
            try:
                raw = self.rfile.read(length)
            finally:
                deadline.cancel()
            if len(raw) != length:
                raise ValueError("incomplete request body")
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("request body is not valid JSON") from exc
        if not isinstance(value, dict):
            raise ValueError("request body must be a JSON object")
        return value

    def _chat(self) -> None:
        with self.runtime.admission_lock:
            if self.runtime.supervisor.paused or self.runtime.recovery_required:
                self._json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "Backend paused for recovery. Use the local dashboard to unload/reload it."})
                return
            self.runtime.active_requests += 1
            self.runtime.active_handlers.add(self)
        try:
            self._chat_inner()
        except OSError:
            # Includes cancelled partial uploads and clients not reading output.
            self.close_connection = True
        finally:
            with self.runtime.admission_lock:
                self.runtime.active_requests -= 1
                self.runtime.active_handlers.discard(self)

    def _chat_inner(self) -> None:
        started = time.monotonic_ns()
        try:
            body = self._read_json()
            raw_messages = body.get("messages")
            if not isinstance(raw_messages, list) or not all(isinstance(item, dict) for item in raw_messages):
                raise ValueError("messages must be a list of objects")
            messages = ollama_to_openai(raw_messages)
            options = body.get("options") if isinstance(body.get("options"), dict) else {}
            try:
                requested_output_tokens = int(options.get("num_predict", self.runtime.config.max_output_tokens))
            except (TypeError, ValueError) as exc:
                raise ValueError("options.num_predict must be a positive integer") from exc
            if requested_output_tokens < 1:
                raise ValueError("options.num_predict must be a positive integer")
            max_tokens = min(requested_output_tokens, self.runtime.config.max_output_tokens)
            prompt_token_limit = min(
                self.runtime.config.session_token_limit,
                self.runtime.config.slot_context_size - max_tokens,
            )
            requested_id = body.get("session_id") or self.headers.get("X-Muse-Session-ID")
            session_id = str(requested_id) if requested_id else derive_session_id(self.runtime.secret, self.client_address[0], raw_messages)
            self.runtime.supervisor.ensure_running()
            self.runtime.supervisor.note_activity()
            try:
                token_count = self.runtime.backend.count_tokens(messages)
                token_counter = self.runtime.backend.count_tokens
            except BackendError:
                token_count = estimate_message_tokens(messages)
                token_counter = None
            decision = self.runtime.manager.begin(
                session_id,
                messages,
                token_count,
                prompt_token_limit=prompt_token_limit,
                token_counter=token_counter,
                token_source="tokenizer" if token_counter else "estimated",
            )
        except ValueError as exc:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        except SessionBusy:
            self._json(HTTPStatus.CONFLICT, {"error": "this conversation already has an active request"})
            return
        except NoSlotAvailable:
            self._json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "all inference slots are busy"})
            return
        except ContextTooLarge as exc:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        except (BackendError, CacheUnavailable) as exc:
            self._json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": str(exc)})
            return

        think = body.get("think")
        payload: Dict[str, Any] = {
            "model": self.runtime.config.model_name,
            "messages": decision.messages,
            "stream": True,
            "stream_options": {"include_usage": True},
            "id_slot": decision.slot_id,
            "cache_prompt": decision.cache_reused,
            "max_tokens": max_tokens,
            "temperature": float(options.get("temperature", 1.0)),
            "top_p": float(options.get("top_p", 0.95)),
            "top_k": int(options.get("top_k", 64)),
        }
        if think is False:
            payload["reasoning_effort"] = "none"
            payload["reasoning_budget_tokens"] = 0
            payload["chat_template_kwargs"] = {"reasoning_strength": "minimal"}

        stream = body.get("stream", True) is not False
        model = self.runtime.config.model_name
        content_parts: List[str] = []
        thinking_parts: List[str] = []
        prompt_tokens = decision.token_count
        completion_tokens = 0
        finish_reason: Optional[str] = None
        success = False
        try:
            if stream:
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/x-ndjson")
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Accel-Buffering", "no")
                self.send_header("X-Muse-Session-ID", session_id)
                self.send_header("Connection", "close")
                self.end_headers()
            if self.runtime.supervisor.paused:
                raise BackendError("Backend manually unloaded; reply interrupted.")
            for event in self.runtime.backend.stream_chat(payload):
                usage = event.get("usage") or {}
                prompt_tokens = int(usage.get("prompt_tokens", prompt_tokens) or prompt_tokens)
                completion_tokens = int(usage.get("completion_tokens", completion_tokens) or completion_tokens)
                choices = event.get("choices") or []
                if not choices:
                    continue
                choice = choices[0]
                if choice.get("finish_reason") is not None:
                    finish_reason = str(choice["finish_reason"])
                delta = choice.get("delta") or {}
                content = delta.get("content") or ""
                thinking = delta.get("reasoning_content") or ""
                if think is False:
                    thinking = ""
                if content:
                    content_parts.append(content)
                if thinking:
                    thinking_parts.append(thinking)
                if stream and (content or thinking):
                    chunk = {
                        "model": model,
                        "created_at": _iso_now(),
                        "message": {"role": "assistant", "content": content, "thinking": thinking or None},
                        "done": False,
                        "session_id": session_id,
                    }
                    self._write_line(chunk)
            if self.runtime.supervisor.paused or finish_reason is None:
                raise BackendError("Backend stopped before the reply completed.")
            success = True
            elapsed = time.monotonic_ns() - started
            final = {
                "model": model,
                "created_at": _iso_now(),
                "message": {"role": "assistant", "content": "" if stream else "".join(content_parts), "thinking": None if stream else "".join(thinking_parts)},
                "done": True,
                "done_reason": ollama_done_reason(finish_reason),
                "total_duration": elapsed,
                "prompt_eval_count": prompt_tokens,
                "eval_count": completion_tokens,
                "session_id": session_id,
                "cache_reused": decision.cache_reused,
                "compacted": decision.compacted,
            }
            if stream:
                self._write_line(final)
            else:
                self._json(HTTPStatus.OK, final, {"X-Muse-Session-ID": session_id})
        except (BackendError, BrokenPipeError, ConnectionResetError) as exc:
            if stream:
                try:
                    self._write_line({"error": str(exc), "done": True, "session_id": session_id})
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
                self._json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})
        finally:
            self.runtime.manager.finish(
                session_id,
                "".join(content_parts),
                "".join(thinking_parts),
                prompt_tokens,
                completion_tokens,
                success and not self.runtime.supervisor.paused,
                duration_ms=(time.monotonic_ns() - started) / 1_000_000,
            )
            self.close_connection = True

    def _heartbeat(self, session_id: str) -> None:
        try:
            session = self.runtime.manager.heartbeat(session_id)
        except SessionNotFound:
            self._json(HTTPStatus.NOT_FOUND, {"error": "session not found or expired"})
            return
        self._json(
            HTTPStatus.OK,
            {
                "session_id": session.session_id,
                "lease_expires_at": datetime.fromtimestamp(session.expires_at, timezone.utc).isoformat().replace("+00:00", "Z"),
                "lease_seconds": self.runtime.config.lease_seconds,
            },
        )

    def _metrics(self) -> None:
        status = self.runtime.manager.status()
        lines = [
            "# HELP muse_active_leases Current unexpired conversation leases.",
            "# TYPE muse_active_leases gauge",
            "muse_active_leases %d" % status["active_leases"],
            "# HELP muse_cached_tokens Estimated tokens associated with live cache slots.",
            "# TYPE muse_cached_tokens gauge",
            "muse_cached_tokens %d" % status["cached_tokens"],
        ]
        for name, value in sorted(status["counters"].items()):
            metric = "muse_%s_total" % name
            lines.extend(["# TYPE %s counter" % metric, "%s %d" % (metric, value)])
        raw = ("\n".join(lines) + "\n").encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _write_line(self, value: Dict[str, Any]) -> None:
        self.wfile.write(json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n")
        self.wfile.flush()

    def _json(self, status: int, value: Dict[str, Any], headers: Optional[Dict[str, str]] = None) -> None:
        raw = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        for name, content in (headers or {}).items():
            self.send_header(name, content)
        self.end_headers()
        self.wfile.write(raw)


class MuseHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: Tuple[str, int], runtime: Runtime) -> None:
        self.runtime = runtime
        super().__init__(address, MuseHandler)


def run() -> None:
    parser = argparse.ArgumentParser(description="Muse Glimmer managed llama.cpp runtime")
    parser.add_argument("--check-config", action="store_true", help="validate configuration and exit")
    args = parser.parse_args()
    config = Config.from_env()
    if args.check_config:
        print("configuration is valid")
        return
    logging.basicConfig(
        level=getattr(logging, config.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    runtime = Runtime(config)
    server = MuseHTTPServer((config.public_host, config.public_port), runtime)

    def shutdown(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        runtime.start()
        LOG.info("Muse Glimmer service ready on http://%s:%d", config.public_host, config.public_port)
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        runtime.close()


if __name__ == "__main__":
    run()
