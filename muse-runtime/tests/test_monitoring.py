import hashlib
import hmac
import json
import os
from pathlib import Path
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.request

from muse_runtime.core import SessionManager, SessionNotFound
from muse_runtime.dashboard import Collector, DashboardServer, psutil
from muse_runtime.monitoring import TelemetryExporter
from test_core import Clock, FakeBackend, messages


class MonitoringTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.backend = FakeBackend()
        self.manager = SessionManager(self.backend, 2, 300, 100, 160, now=self.clock)

    def finish(self, sid):
        self.manager.finish(sid, "PRIVATE response", "PRIVATE reasoning", 10, 2, True, duration_ms=150)

    def test_monitor_reads_do_not_renew_or_reap_and_record_exact_renewals(self):
        self.manager.begin("PRIVATE session ID", messages("PRIVATE prompt"), 10)
        self.finish("PRIVATE session ID")
        self.clock.advance(200)
        self.manager.heartbeat("PRIVATE session ID")
        expires = self.manager.sessions["PRIVATE session ID"].expires_at
        for _ in range(100):
            snapshot = self.manager.monitor_snapshot()
        renewals = [e for e in snapshot["events"] if e["kind"] == "lease_renewed"]
        self.assertEqual(["request_started", "request_completed", "heartbeat"], [e["reason"] for e in renewals])
        self.assertEqual([1000, 1000, 1200], [e["at"] for e in renewals])
        self.assertEqual(expires, self.manager.sessions["PRIVATE session ID"].expires_at)
        self.assertNotIn("PRIVATE", json.dumps(snapshot))
        self.assertEqual(1, len({e["session"] for e in renewals}))
        self.clock.advance(301)
        self.assertEqual("awaiting_expiry", self.manager.monitor_snapshot()["sessions"][0]["state"])
        self.assertEqual(0, self.manager.counters["expirations"])
        self.manager.reap_expired()
        self.assertEqual([], self.manager.monitor_snapshot()["sessions"])
        self.assertEqual("lease_expired", self.manager.events[-1]["kind"])

    def test_busy_work_remains_protected_without_monitor_activity(self):
        self.manager.begin("busy", messages(), 10)
        self.clock.advance(301)
        self.assertEqual("busy", self.manager.monitor_snapshot()["sessions"][0]["state"])
        self.assertEqual(0, self.manager.reap_expired())
        self.finish("busy")
        self.assertEqual(1601, self.manager.sessions["busy"].expires_at)

    def test_public_restart_id_cannot_reproduce_private_conversation_aliases(self):
        sid = "guessable-private-conversation"
        self.manager.begin(sid, messages(), 10)
        self.finish(sid)
        snapshot = self.manager.monitor_snapshot()
        alias = snapshot["sessions"][0]["session"]
        guessed_alias = hmac.new(bytes.fromhex(snapshot["boot_id"]), sid.encode(), hashlib.sha256).hexdigest()[:16]
        self.assertNotEqual(guessed_alias, alias)
        self.assertNotIn(self.manager._monitor_alias_key.hex(), json.dumps(snapshot))
        self.assertTrue(all(event["session"] == alias for event in snapshot["events"] if "session" in event))
        # Even a repeated public restart ID must not repeat the private alias key.
        restarted = SessionManager(self.backend, 2, 300, 100, 160, now=self.clock)
        restarted.monitor_id = snapshot["boot_id"]
        self.assertNotEqual(alias, restarted.session_ref(sid))

    def test_every_same_instant_heartbeat_is_retained_until_history_rolls_over(self):
        self.manager.begin("one", messages(), 10)
        for _ in range(600):
            self.manager.heartbeat("one")
        snapshot = self.manager.monitor_snapshot()
        self.assertEqual(512, len(snapshot["events"]))
        self.assertEqual(512, snapshot["event_capacity"])
        self.assertEqual(snapshot["event_sequence"] - 512, snapshot["events_dropped"])
        self.assertEqual(512, len({e["sequence"] for e in snapshot["events"]}))

    def test_eviction_compaction_and_failure_events_are_correlated(self):
        for sid in ("one", "two", "three"):
            self.manager.begin(sid, messages(), 10)
            self.finish(sid)
        evicted = [e for e in self.manager.events if e["kind"] == "cache_evicted"]
        self.assertEqual("slot_pressure", evicted[0]["reason"])
        self.assertEqual(self.manager.session_ref("one"), evicted[0]["session"])
        self.manager.begin("long", messages("long", 400), 500)
        self.manager.finish("long", "", "", 10, 0, False)
        kinds = [e["kind"] for e in self.manager.events]
        self.assertIn("compaction_completed", kinds)
        self.assertIn("cache_rebuild", kinds)
        self.assertIn("request_failed", kinds)
        with self.assertRaises(SessionNotFound):
            self.manager.heartbeat("missing")
        self.assertEqual("heartbeat_rejected", self.manager.events[-1]["kind"])

    def test_token_pressure_reason_and_erase_failure_do_not_change_policy(self):
        self.manager.begin("one", messages(), 80)
        self.manager.finish("one", "", "", 80, 2, True)
        self.backend.erase_slot = Mock(return_value=False)
        self.manager.begin("two", messages(), 90)
        self.assertIsNone(self.manager.sessions["one"].slot_id)
        kinds = {e["kind"]: e for e in self.manager.events}
        self.assertIn("cache_erase_failed", kinds)
        self.assertEqual("token_pressure", kinds["cache_evicted"]["reason"])

    def test_session_exports_and_history_are_bounded(self):
        for i in range(300):
            self.manager.begin(str(i), messages(), 10)
            self.finish(str(i))
        snapshot = self.manager.monitor_snapshot()
        self.assertEqual(256, len(snapshot["sessions"]))
        self.assertEqual(44, snapshot["sessions_omitted"])
        self.assertLess(len(json.dumps(snapshot)), 300_000)


class ExportAndDashboardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        manager = SessionManager(FakeBackend(), 4, 300, 8192, 24576)
        config = SimpleNamespace(state_dir=self.path, model_name="test-model", lease_seconds=300,
                                 session_token_limit=8192, total_cache_token_limit=24576,
                                 context_size=32768, slot_context_size=8192, slots=4,
                                 max_output_tokens=2048, snapshot_mode="disabled",
                                 model_unload_policy="keep_loaded", model_idle_seconds=900)
        supervisor = Mock()
        supervisor.status.return_value = {"loaded": True, "pid": os.getpid(), "uptime_seconds": 10, "unload_policy": "keep_loaded"}
        self.runtime = SimpleNamespace(manager=manager, config=config, supervisor=supervisor)
        self.exporter = TelemetryExporter(self.runtime)
        self.collector = Collector(self.path)

    def test_atomic_private_export_no_model_activity_and_no_private_content(self):
        self.runtime.manager.begin("PRIVATE", messages("PRIVATE"), 10)
        self.exporter.write_once()
        self.assertEqual(0o600, (self.path / "monitor.json").stat().st_mode & 0o777)
        self.assertNotIn("PRIVATE", (self.path / "monitor.json").read_text())
        self.runtime.supervisor.ensure_running.assert_not_called()
        self.runtime.supervisor.note_activity.assert_not_called()
        self.assertFalse((self.path / "monitor.tmp").exists())

    def test_missing_live_stale_corrupt_and_restart_states(self):
        self.assertEqual("disconnected", self.collector.sample()["connection"])
        self.exporter.write_once()
        first = self.collector.sample()
        self.assertEqual("live", first["connection"])
        source = json.loads((self.path / "monitor.json").read_text())
        source["sampled_at"] -= 20
        (self.path / "monitor.json").write_text(json.dumps(source))
        self.assertEqual("stale", self.collector.sample()["connection"])
        (self.path / "monitor.json").write_text("invalid")
        self.assertEqual("disconnected", self.collector.sample()["connection"])
        self.exporter.write_once()
        self.runtime.manager = SessionManager(FakeBackend(), 4, 300, 8192, 24576)
        TelemetryExporter(self.runtime).write_once()
        self.assertEqual(1, self.collector.sample()["restarts_observed"])

    @unittest.skipIf(psutil is None, "producer process checks require requirements-monitor.txt")
    def test_dead_producer_process_disconnects_even_with_fresh_snapshot(self):
        self.exporter.write_once()
        with patch.object(self.collector, "_process", return_value=None):
            self.assertEqual("disconnected", self.collector.sample()["connection"])

    def test_bounded_resource_history_and_optional_resource_support(self):
        for _ in range(100):
            self.collector.sample()
        self.assertLessEqual(len(self.collector.history), 90)
        self.exporter.write_once()
        with patch("muse_runtime.dashboard.psutil", None):
            value = self.collector.sample()
            self.assertIsNone(value["host"])
            self.assertFalse(value["resource_metrics_available"])
            self.assertEqual("live", value["connection"])  # freshness-only without process support
            self.assertTrue(all(process is None for process in value["processes"].values()))

    def test_http_is_loopback_read_only_and_rejects_cross_origin_or_private_paths(self):
        self.exporter.write_once()
        self.collector.sample()
        server = DashboardServer(0, self.collector)
        self.assertEqual("127.0.0.1", server.server_address[0])
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = "http://127.0.0.1:%d" % server.server_port
        with urllib.request.urlopen(url + "/api/monitor") as response:
            self.assertEqual("no-store", response.headers["Cache-Control"])
            self.assertIsNone(response.headers.get("Access-Control-Allow-Origin"))
            self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])
            self.assertEqual("live", json.load(response)["connection"])
        # A link may open the static page, but a foreign site cannot fetch telemetry.
        request = urllib.request.Request(url, headers={"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"})
        with urllib.request.urlopen(request) as response:
            self.assertEqual(200, response.status)
        for path, headers, method, code in [
            ("/", {"Host": "evil.example"}, "GET", 403),
            ("/api/monitor", {"Origin": "https://evil.example"}, "GET", 403),
            ("/api/monitor", {"Sec-Fetch-Site": "cross-site"}, "GET", 403),
            ("/../state/session-secret", {}, "GET", 404),
            ("/api/sessions/one/heartbeat", {}, "POST", 403),
        ]:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(urllib.request.Request(url + path, headers=headers, method=method))
            self.assertEqual(code, caught.exception.code)


if __name__ == "__main__":
    unittest.main()
