"""Exercise real HTTP handlers/reaper with an isolated backend, never production slots."""
from dataclasses import replace
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
import urllib.request

from muse_runtime.config import Config
from muse_runtime.server import Runtime, MuseHTTPServer
from muse_runtime.dashboard import Collector, DashboardServer
from test_core import FakeBackend


class StreamingBackend(FakeBackend):
    def health(self):
        return True

    def count_tokens(self, _messages):
        return 10

    def stream_chat(self, _payload):
        yield {"choices": [{"delta": {"content": "PRIVATE fixture reply"}, "finish_reason": "stop"}],
               "usage": {"prompt_tokens": 10, "completion_tokens": 3}}


class MonitorHTTPTests(unittest.TestCase):
    def test_streaming_renewal_and_real_reaper_expiry_while_dashboard_is_polled(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.dict("os.environ", {"MUSE_BACKEND_AUTOSTART": "false"}):
                config = replace(Config.from_env(), state_dir=Path(temporary), lease_seconds=1)
            runtime = Runtime(config)
            backend = StreamingBackend()
            runtime.backend = backend
            runtime.manager.backend = backend
            supervisor = Mock()
            supervisor.paused = False
            supervisor.process = None
            supervisor.status.return_value = {"loaded": True, "pid": None, "uptime_seconds": 0}
            runtime.supervisor = supervisor
            chat = MuseHTTPServer(("127.0.0.1", 0), runtime)
            collector = Collector(Path(temporary))
            dashboard = DashboardServer(0, collector)
            for server in (chat, dashboard):
                threading.Thread(target=server.serve_forever, daemon=True).start()
            runtime.start()
            runtime.telemetry.close()  # explicit writes below; keep the real reaper running
            url = "http://127.0.0.1:%d" % chat.server_port
            monitor = "http://127.0.0.1:%d/api/monitor" % dashboard.server_port
            try:
                body = {"session_id": "PRIVATE isolated test", "messages": [{"role": "user", "content": "PRIVATE prompt"}], "stream": True}
                req = urllib.request.Request(url + "/api/chat", json.dumps(body).encode(), {"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=3) as response:
                    chunks = [json.loads(line) for line in response]
                    self.assertEqual(body["session_id"], response.headers["X-Muse-Session-ID"])
                self.assertTrue(chunks[-1]["done"])
                self.assertEqual("PRIVATE fixture reply", chunks[0]["message"]["content"])
                # Use a URL-safe ID for the public heartbeat path in a separate chat.
                req = urllib.request.Request(url + "/api/chat", json.dumps(dict(body, session_id="isolated")).encode(), {"Content-Type": "application/json"})
                urllib.request.urlopen(req, timeout=3).read()
                urllib.request.urlopen(urllib.request.Request(url + "/api/sessions/isolated/heartbeat", data=b"{}"), timeout=3).read()
                expires = runtime.manager.sessions["isolated"].expires_at
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline and runtime.manager.active_lease_count():
                    runtime.telemetry.write_once()
                    collector.sample()
                    with urllib.request.urlopen(monitor, timeout=2) as response:
                        sample = json.load(response)
                    self.assertNotIn("PRIVATE", json.dumps(sample))
                    self.assertEqual(1, runtime.manager.counters["heartbeats"])
                    session = runtime.manager.sessions.get("isolated")
                    if session:
                        self.assertEqual(expires, session.expires_at)
                    time.sleep(.1)
                # active_lease_count falls to zero before the one-second reaper removes rows.
                deadline = time.monotonic() + 2
                while runtime.manager.sessions and time.monotonic() < deadline:
                    time.sleep(.1)
                self.assertEqual({}, runtime.manager.sessions)
                self.assertEqual(2, runtime.manager.counters["expirations"])
                self.assertEqual(2, supervisor.ensure_running.call_count)  # chats only
                self.assertEqual(2, supervisor.note_activity.call_count)
                kinds = [e["kind"] for e in runtime.manager.events]
                self.assertIn("lease_expired", kinds)
                self.assertEqual(5, kinds.count("lease_renewed"))  # start/end twice + heartbeat
            finally:
                for server in (dashboard, chat):
                    server.shutdown()
                    server.server_close()
                runtime.close()
