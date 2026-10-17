"""Control behavior with real HTTP boundaries and isolated processes/backends."""
from dataclasses import replace
import json
import os
from pathlib import Path
import subprocess
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest.mock import Mock, patch

from muse_runtime.backend import BackendError, HttpLlamaBackend, ModelSupervisor
from muse_runtime.config import Config
from muse_runtime.core import CacheUnavailable
from muse_runtime.dashboard import Collector, DashboardServer
from muse_runtime.server import Runtime, MuseHTTPServer
from test_core import FakeBackend, messages


class ControlsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        with patch.dict(os.environ, {"MUSE_BACKEND_AUTOSTART": "false"}):
            self.config = replace(Config.from_env(), state_dir=Path(self.tmp.name))
        self.runtime = Runtime(self.config)
        self.backend = FakeBackend()
        self.backend.health = lambda: False
        self.runtime.manager.backend = self.backend
        self.runtime.supervisor.backend = self.backend
        self.manager = self.runtime.manager

    def seed(self, sid="one"):
        self.manager.begin(sid, messages("phone history"), 10)
        self.manager.finish(sid, "answer", "", 10, 2, True)
        return self.manager.sessions[sid]

    def control(self, action, **kwargs):
        return self.runtime.controls.execute(dict(action=action, **kwargs))

    def test_reset_keeps_live_state_and_operational_totals_with_bounded_new_history(self):
        session = self.seed()
        self.manager.begin("busy", messages(), 10)
        before = self.manager.status()
        history = list(session.messages)
        self.assertTrue(self.control("reset")["ok"])
        self.assertEqual(before, self.manager.status())
        self.assertEqual(history, session.messages)
        self.assertEqual([], self.manager.monitor_snapshot()["events"])
        self.assertTrue(all(v == 0 for v in self.manager.monitor_snapshot()["counters"].values()))
        self.manager.heartbeat("one")
        self.assertEqual(1, self.manager.monitor_snapshot()["counters"]["heartbeats"])
        for _ in range(600):
            self.manager.record_event("test")
        self.assertEqual(512, len(self.manager.events))

    def test_reset_fences_stale_export_and_other_dashboard_polling(self):
        self.seed()
        self.runtime.telemetry.write_once()
        collector = Collector(self.config.state_dir)
        collector.sample()
        result = self.control("reset")
        collector.reset_history(result["window_id"], result["boot_id"], result["window_sequence"], result["producer_generation"])
        for _ in range(3):
            self.assertIsNone(collector.sample()["runtime"])
        self.runtime.telemetry.write_once()
        fresh = collector.sample()
        self.assertEqual(result["window_id"], fresh["runtime"]["window_id"])
        self.assertEqual([], fresh["runtime"]["events"])
        self.assertLessEqual(len(fresh["history"]), 90)

    def test_selected_eviction_preserves_other_cache_history_and_lease_heartbeat_cannot_restore(self):
        one, two = self.seed(), self.seed("two")
        history, expiry, other_slot = list(one.messages), one.expires_at, two.slot_id
        one.snapshot_filename = "old.bin"
        result = self.control("evict", target=self.manager.session_ref("one"))
        self.assertTrue(result["ok"])
        self.assertEqual(history, one.messages)
        self.assertEqual(expiry, one.expires_at)
        self.assertEqual(other_slot, two.slot_id)
        self.assertTrue(two.cache_valid)
        self.assertIn("old.bin", self.backend.deleted)
        self.manager.heartbeat("one")
        self.assertFalse(one.cache_valid)
        self.assertIsNone(one.slot_id)
        decision = self.manager.begin("one", history, 12)
        self.assertFalse(decision.cache_reused)
        self.assertFalse(decision.restored)
        self.assertEqual(history, decision.messages)

    def test_reset_fence_accepts_newer_reset_or_runtime_restart(self):
        self.runtime.telemetry.write_once()
        collector = Collector(self.config.state_dir)
        collector.sample()
        first = self.control("reset")
        collector.reset_history(first["window_id"], first["boot_id"], first["window_sequence"], first["producer_generation"])
        second = self.control("reset")
        self.runtime.telemetry.write_once()
        self.assertEqual(second["window_id"], collector.sample()["runtime"]["window_id"])
        third = self.control("reset")
        collector.reset_history(third["window_id"], third["boot_id"], third["window_sequence"], third["producer_generation"])
        restarted = Runtime(self.config)
        restarted.supervisor.backend.health = lambda: False
        restarted.telemetry.write_once()
        self.assertEqual(restarted.manager.monitor_id, collector.sample()["runtime"]["boot_id"])

    def test_reset_before_new_producer_first_export_rejects_previous_producer(self):
        self.seed()
        self.runtime.telemetry.write_once()
        previous = (self.config.state_dir / "monitor.json").read_bytes()
        collector = Collector(self.config.state_dir)
        collector.sample()
        restarted = Runtime(self.config)
        restarted.supervisor.backend.health = lambda: False
        # Match the runtime's ready state before reset without exporting anything.
        restarted.telemetry.snapshot()
        result = restarted.controls.execute({"action": "reset"})
        self.assertTrue(result["ok"])
        for reader in (collector, Collector(self.config.state_dir)):
            reader.reset_history(result["window_id"], result["boot_id"], result["window_sequence"], result["producer_generation"])
            for _ in range(3):
                self.assertIsNone(reader.sample()["runtime"])
        restarted.telemetry.write_once()
        fresh = collector.sample()["runtime"]
        self.assertEqual(result["window_id"], fresh["window_id"])
        self.assertEqual([], fresh["events"])
        # A late old export cannot undo the fence after a matching one arrives.
        (self.config.state_dir / "monitor.json").write_bytes(previous)
        self.assertEqual(fresh, collector.sample()["runtime"])
        self.assertEqual("disconnected", collector.snapshot()["connection"])

    def test_generation_survives_missing_export(self):
        old_generation = self.runtime.telemetry.generation
        restarted = Runtime(self.config)
        self.assertGreater(restarted.telemetry.generation, old_generation)
        self.assertFalse((self.config.state_dir / "monitor.json").exists())
        self.assertEqual(0o600, (self.config.state_dir / "monitor-generation").stat().st_mode & 0o777)

    def test_late_reset_reply_cannot_lower_collector_window(self):
        first = self.control("reset")
        second = self.control("reset")
        self.runtime.telemetry.write_once()
        collector = Collector(self.config.state_dir)
        collector.sample()
        collector.reset_history(first["window_id"], first["boot_id"], first["window_sequence"], first["producer_generation"])
        self.assertEqual(second["window_id"], collector.sample()["runtime"]["window_id"])

    def test_busy_requests_empty_targets_and_failed_erasure(self):
        self.assertFalse(self.control("evict", target="missing")["ok"])
        self.assertTrue(self.control("evict", target="all")["ok"])
        self.assertEqual(list(range(4)), self.backend.erased)
        one = self.seed()
        self.runtime.active_requests = 1
        self.assertFalse(self.control("evict", target="all")["ok"])
        self.runtime.active_requests = 0
        self.backend.erase_slot = Mock(return_value=False)
        old_slot = one.slot_id
        self.assertFalse(self.control("evict", target="all")["ok"])
        self.assertEqual(old_slot, one.slot_id)
        self.assertFalse(one.cache_valid)
        self.assertTrue(self.runtime.recovery_required)
        self.assertFalse(self.control("reload")["ok"])

    def test_concurrent_heartbeat_cannot_rebuild_and_second_control_fails_fast(self):
        one = self.seed()
        entered, release = threading.Event(), threading.Event()
        def erase(_slot):
            entered.set()
            release.wait(2)
            return True
        self.backend.erase_slot = erase
        result = []
        worker = threading.Thread(target=lambda: result.append(self.control("evict", target=self.manager.session_ref("one"))))
        worker.start()
        self.assertTrue(entered.wait(1))
        self.assertFalse(self.control("reset")["ok"])
        heartbeat = threading.Thread(target=lambda: self.manager.heartbeat("one"))
        heartbeat.start()
        release.set()
        worker.join(3)
        heartbeat.join(3)
        self.assertTrue(result[0]["ok"])
        self.assertFalse(one.cache_valid)
        self.assertIsNone(one.slot_id)

    def test_hung_erase_has_total_deadline_and_allows_unload_recovery(self):
        self.seed()
        self.runtime.supervisor.process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
        process = self.runtime.supervisor.process
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        release = threading.Event()
        self.backend.erase_slot = lambda _slot: release.wait(5)
        try:
            start = time.monotonic()
            with patch("muse_runtime.core.ERASE_WAIT_SECONDS", .05):
                result = self.control("evict", target="all")
            self.assertLess(time.monotonic() - start, .5)
            self.assertFalse(result["ok"])
            self.assertTrue(self.runtime.recovery_required)
            self.assertTrue(self.control("unload")["ok"])
            self.assertIsNone(self.manager.sessions["one"].slot_id)
        finally:
            release.set()

    def test_supervised_process_stops_pause_survives_new_supervisor_no_auto_load(self):
        self.seed()
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        self.runtime.supervisor.process = process
        self.assertTrue(self.control("unload")["ok"])
        self.assertIsNotNone(process.poll())
        self.assertTrue(self.runtime.supervisor.paused)
        self.assertIsNone(self.manager.sessions["one"].slot_id)
        with self.assertRaises(CacheUnavailable):
            self.manager.begin("late-tokenizer", messages(), 10)
        self.manager.heartbeat("one")
        self.runtime.supervisor.status()
        fresh = ModelSupervisor(self.config, self.backend)
        self.assertTrue(fresh.paused)
        with self.assertRaises(BackendError):
            fresh.ensure_running()
        self.assertIsNone(fresh.process)
        self.runtime.active_requests = 1
        self.assertFalse(self.control("reload")["ok"])

    def test_unload_interrupts_active_http_stream_without_marking_cache_reusable(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        self.runtime.supervisor.process = process
        self.runtime.supervisor.ensure_running = Mock()
        self.backend.count_tokens = lambda _messages: 10
        streaming = threading.Event()
        def stream(payload):
            self.assertFalse(payload["cache_prompt"])
            yield {"choices": [{"delta": {"content": "first"}}]}
            streaming.set()
            while process.poll() is None:
                time.sleep(.01)
        self.backend.stream_chat = stream
        self.runtime.backend = self.backend
        server = MuseHTTPServer(("127.0.0.1", 0), self.runtime)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        result = []
        def chat():
            request = urllib.request.Request("http://127.0.0.1:%d/api/chat" % server.server_port,
                json.dumps({"session_id": "streaming", "messages": messages()}).encode())
            with urllib.request.urlopen(request, timeout=5) as response:
                result.extend(json.loads(line) for line in response)
        worker = threading.Thread(target=chat)
        worker.start()
        self.assertTrue(streaming.wait(2))
        self.assertFalse(self.control("evict", target="all")["ok"])
        self.assertTrue(self.control("unload")["ok"])
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertFalse(any(item.get("done") and "error" not in item for item in result))
        deadline = time.monotonic() + 2
        while self.runtime.active_requests and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(0, self.runtime.active_requests)
        self.assertFalse(self.manager.sessions["streaming"].cache_valid)
        self.assertIsNone(self.manager.sessions["streaming"].slot_id)

    def test_stuck_passive_health_does_not_hold_stop_lock(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        self.runtime.supervisor.process = process
        entered, release = threading.Event(), threading.Event()
        def health():
            entered.set()
            release.wait(5)
            return True
        self.backend.health = health
        probe = threading.Thread(target=self.runtime.supervisor.status, daemon=True)
        probe.start()
        self.assertTrue(entered.wait(1))
        try:
            started = time.monotonic()
            self.assertTrue(self.control("unload")["ok"])
            self.assertLess(time.monotonic() - started, 1)
            self.assertIsNotNone(process.poll())
        finally:
            release.set()
            probe.join(2)

    def test_health_has_total_wait_and_one_outstanding_probe(self):
        backend = HttpLlamaBackend(self.config)
        release = threading.Event()
        backend._request = Mock(side_effect=lambda *_a, **_k: release.wait(5))
        try:
            started = time.monotonic()
            self.assertFalse(backend.health())
            self.assertLess(time.monotonic() - started, 3)
            self.assertFalse(backend.health())
            self.assertEqual(1, backend._request.call_count)
        finally:
            release.set()

    def test_unload_cancels_partial_upload_and_stalled_output_then_reload_can_proceed(self):
        for stalled_output in (False, True):
            with self.subTest(stalled_output=stalled_output):
                process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
                self.runtime.supervisor.process = process
                self.runtime.supervisor.paused = False
                self.runtime.recovery_required = False
                self.manager.admission_paused.clear()
                self.runtime.supervisor.ensure_running = Mock()
                self.backend.count_tokens = lambda _messages: 10
                writing = threading.Event()
                def stream(_payload):
                    writing.set()
                    for _ in range(1000):
                        yield {"choices": [{"delta": {"content": "x" * 262144}}]}
                self.backend.stream_chat = stream
                self.runtime.backend = self.backend
                server = MuseHTTPServer(("127.0.0.1", 0), self.runtime)
                threading.Thread(target=server.serve_forever, daemon=True).start()
                client = socket.create_connection(server.server_address)
                client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                try:
                    body = json.dumps({"session_id": "stalled-output", "messages": messages()}).encode() if stalled_output else b"{"
                    length = len(body) if stalled_output else 100
                    client.sendall(("POST /api/chat HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n" % length).encode() + body)
                    deadline = time.monotonic() + 2
                    while not self.runtime.active_requests and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertEqual(1, self.runtime.active_requests)
                    if stalled_output:
                        self.assertTrue(writing.wait(1))
                    self.assertTrue(self.control("unload")["ok"])
                    deadline = time.monotonic() + 2
                    while self.runtime.active_requests and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertEqual(0, self.runtime.active_requests)
                    self.runtime.supervisor.reload = Mock()
                    self.assertTrue(self.control("reload")["ok"])
                    self.runtime.supervisor.reload.assert_called_once()
                finally:
                    client.close()
                    server.shutdown()
                    server.server_close()
                    if process.poll() is None:
                        process.kill()
                        process.wait()

    def test_unmanaged_backend_not_killed_or_claimed_released(self):
        self.backend.health = lambda: True
        result = self.control("unload")
        self.assertFalse(result["ok"])
        self.assertIn("externally managed", result["message"])
        self.assertTrue(self.runtime.supervisor.paused)

    def test_empty_idle_and_restored_pause_allow_explicit_reload_and_repeat_unload(self):
        for state in ("never_loaded", "idle_unloaded", "persisted_pause"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as tmp:
                config = replace(self.config, state_dir=Path(tmp), backend_autostart=True)
                if state == "persisted_pause":
                    (config.state_dir / "backend-paused").touch()
                runtime = Runtime(config)
                supervisor = runtime.supervisor
                def start():
                    supervisor.process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
                    supervisor.started_at = time.time()
                supervisor._start = Mock(side_effect=start)
                supervisor.backend.health = lambda: supervisor.process is not None and supervisor.process.poll() is None
                try:
                    if state == "idle_unloaded":
                        start()
                        supervisor.stop()
                    first = runtime.controls.execute({"action": "unload"})
                    self.assertFalse(first["ok"])
                    self.assertIn("No memory release is claimed", first["message"])
                    self.assertTrue(supervisor.paused)
                    self.assertFalse(runtime.recovery_required)
                    self.assertTrue(runtime.controls.execute({"action": "reload"})["ok"])
                    supervisor._start.assert_called_once()
                    self.assertFalse(runtime.manager.admission_paused.is_set())
                    self.assertTrue(runtime.controls.execute({"action": "unload"})["ok"])
                    again = runtime.controls.execute({"action": "unload"})
                    self.assertTrue(again["ok"])
                    self.assertIn("No additional memory release", again["message"])
                    self.assertTrue(runtime.controls.execute({"action": "reload"})["ok"])
                finally:
                    supervisor.stop()

    def test_empty_unload_does_not_clear_real_erase_quarantine_or_probe_health(self):
        self.seed()
        self.backend.erase_slot = Mock(return_value=False)
        self.assertFalse(self.control("evict", target="all")["ok"])
        self.backend.health = Mock(side_effect=AssertionError("unload must not probe health"))
        for _ in range(2):
            result = self.control("unload")
            self.assertFalse(result["ok"])
            self.assertTrue(self.runtime.recovery_required)
            self.assertFalse(self.control("reload")["ok"])
        self.backend.health.assert_not_called()

    def test_http_origin_token_protection_and_private_bridge(self):
        self.seed()
        self.runtime.controls.start()
        self.addCleanup(self.runtime.controls.close)
        self.assertEqual(0o600, self.runtime.controls.path.stat().st_mode & 0o777)
        collector = Collector(self.config.state_dir)
        self.runtime.telemetry.write_once()
        collector.sample()
        server = DashboardServer(0, collector)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = "http://127.0.0.1:%d" % server.server_port
        headers = {"Origin": url, "Content-Type": "application/json", "X-Dashboard-Token": server.token}
        for change in [{"Origin": "http://evil.test"}, {"Origin": ""}, {"X-Dashboard-Token": "wrong"}, {"Host": "evil.test"}, {"Sec-Fetch-Site": "cross-site"}, {"Content-Type": "text/plain"}]:
            request = urllib.request.Request(url + "/api/control", b'{"action":"reset"}', dict(headers, **change))
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request)
            self.assertEqual(403, caught.exception.code)
        self.assertTrue(self.manager.events)
        request = urllib.request.Request(url + "/api/control", b'{"action":"reset"}', headers)
        self.assertTrue(json.load(urllib.request.urlopen(request))["ok"])
        private = "http://127.0.0.1:%d/control" % self.runtime.controls.server.server_port
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(urllib.request.Request(private, b'{"action":"unload"}'))
        self.assertEqual(403, caught.exception.code)
        # Removing the bridge produces a visible failure, not a pretend reset.
        self.runtime.controls.path.unlink()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request)
        self.assertEqual(503, caught.exception.code)

    def test_phone_listener_does_not_expose_controls(self):
        server = MuseHTTPServer(("127.0.0.1", 0), self.runtime)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:%d/api/control" % server.server_port, b'{"action":"unload"}'))
        self.assertEqual(404, caught.exception.code)


if __name__ == "__main__":
    unittest.main()
