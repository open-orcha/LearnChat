import unittest

from muse_runtime.core import ContextTooLarge, SessionManager, compact_messages, estimate_message_tokens


class Clock:
    def __init__(self):
        self.value = 1_000.0

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += seconds


class FakeBackend:
    def __init__(self):
        self.erased = []
        self.saved = []
        self.restored = []
        self.deleted = []
        self.restore_ok = True

    def erase_slot(self, slot_id):
        self.erased.append(slot_id)
        return True

    def save_slot(self, slot_id, filename):
        self.saved.append((slot_id, filename))
        return True

    def restore_slot(self, slot_id, filename):
        self.restored.append((slot_id, filename))
        return self.restore_ok

    def delete_snapshot(self, filename):
        self.deleted.append(filename)


def messages(label="hello", repeats=1):
    return [{"role": "user", "content": (label + " ") * repeats}]


class SessionManagerTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.backend = FakeBackend()
        self.manager = SessionManager(
            self.backend,
            slots=2,
            lease_seconds=300,
            session_token_limit=100,
            total_cache_token_limit=160,
            now=self.clock,
        )

    def complete(self, session_id, decision, prompt_tokens=10):
        self.manager.finish(session_id, "answer", "", prompt_tokens, 2, True)

    def test_same_session_reuses_the_same_cache_slot(self):
        first = self.manager.begin("one", messages(), 10)
        self.complete("one", first)
        self.clock.advance(1)
        second = self.manager.begin("one", messages("hello again"), 14)
        self.assertEqual(first.slot_id, second.slot_id)
        self.assertTrue(second.cache_reused)
        self.assertEqual(1, self.manager.counters["cache_reuses"])

    def test_heartbeat_renews_lease(self):
        decision = self.manager.begin("one", messages(), 10)
        self.complete("one", decision)
        original = self.manager.sessions["one"].expires_at
        self.clock.advance(200)
        renewed = self.manager.heartbeat("one")
        self.assertGreater(renewed.expires_at, original)
        self.assertEqual(1, self.manager.counters["heartbeats"])

    def test_expired_session_releases_slot(self):
        decision = self.manager.begin("one", messages(), 10)
        self.complete("one", decision)
        self.clock.advance(301)
        self.assertEqual(1, self.manager.reap_expired())
        self.assertNotIn("one", self.manager.sessions)
        self.assertEqual([decision.slot_id], self.backend.erased)

    def test_slot_pressure_evicts_least_recently_used_deterministically(self):
        first = self.manager.begin("a", messages("a"), 30)
        self.complete("a", first, 30)
        self.clock.advance(1)
        second = self.manager.begin("b", messages("b"), 30)
        self.complete("b", second, 30)
        self.clock.advance(1)
        third = self.manager.begin("c", messages("c"), 30)
        self.assertIsNone(self.manager.sessions["a"].slot_id)
        self.assertEqual(first.slot_id, third.slot_id)
        self.assertEqual(1, self.manager.counters["evictions"])

    def test_total_token_bound_forces_lru_eviction(self):
        first = self.manager.begin("a", messages("a"), 80)
        self.complete("a", first, 78)
        self.clock.advance(1)
        second = self.manager.begin("b", messages("b"), 80)
        self.assertIsNone(self.manager.sessions["a"].slot_id)
        self.assertIsNotNone(self.manager.sessions["b"].slot_id)
        self.assertGreaterEqual(self.manager.counters["evictions"], 1)

    def test_over_bound_active_conversation_compacts_and_rebuilds(self):
        original = [
            {"role": "user" if i % 2 == 0 else "assistant", "content": ("turn-%d " % i) * 40}
            for i in range(8)
        ]
        decision = self.manager.begin("long", original, 500)
        self.assertTrue(decision.compacted)
        self.assertLessEqual(estimate_message_tokens(decision.messages), 100)
        self.assertIn("Conversation summary", "\n".join(str(m.get("content")) for m in decision.messages))
        self.assertEqual(1, self.manager.counters["compactions"])
        self.assertEqual(1, self.manager.counters["fallback_rebuilds"])

    def test_compaction_recounts_with_a_tokenizer_that_exceeds_the_estimate(self):
        original = [
            {"role": "user" if i % 2 == 0 else "assistant", "content": ("turn-%d " % i) * 40}
            for i in range(8)
        ]

        def real_counter(candidate):
            return estimate_message_tokens(candidate) * 2

        decision = self.manager.begin("long", original, 150, token_counter=real_counter)
        self.assertTrue(decision.compacted)
        self.assertLessEqual(decision.token_count, 100)
        self.assertEqual(real_counter(decision.messages), decision.token_count)

    def test_output_headroom_can_trigger_compaction_before_session_limit(self):
        original = [
            {"role": "user" if i % 2 == 0 else "assistant", "content": ("turn-%d " % i) * 30}
            for i in range(6)
        ]
        decision = self.manager.begin("headroom", original, 90, prompt_token_limit=60)
        self.assertTrue(decision.compacted)
        self.assertLessEqual(decision.token_count, 60)

    def test_uncompacted_real_context_failure_is_clean(self):
        with self.assertRaisesRegex(ContextTooLarge, "safe 100-token prompt limit"):
            self.manager.begin("impossible", messages("large", 100), 500, token_counter=lambda _: 500)

    def test_failed_snapshot_restore_falls_back_to_message_rebuild(self):
        manager = SessionManager(
            self.backend,
            slots=1,
            lease_seconds=300,
            session_token_limit=100,
            total_cache_token_limit=100,
            snapshot_mode="best_effort",
            now=self.clock,
        )
        first = manager.begin("a", messages("a"), 20)
        manager.finish("a", "answer", "", 20, 2, True)
        self.clock.advance(1)
        second = manager.begin("b", messages("b"), 20)
        manager.finish("b", "answer", "", 20, 2, True)
        self.backend.restore_ok = False
        self.clock.advance(1)
        rebuilt = manager.begin("a", messages("a again"), 24)
        self.assertFalse(rebuilt.restored)
        self.assertFalse(rebuilt.cache_reused)
        self.assertEqual(1, manager.counters["fallback_rebuilds"])
        self.assertGreaterEqual(len(self.backend.restored), 1)


class CompactionTests(unittest.TestCase):
    def test_compaction_drops_images_from_old_turns(self):
        source = [
            {"role": "user", "content": "old details " * 80, "images": ["very-secret-base64"]},
            {"role": "assistant", "content": "old answer " * 80},
            {"role": "user", "content": "new question"},
        ]
        result = compact_messages(source, 120)
        self.assertLessEqual(estimate_message_tokens(result), 120)
        self.assertNotIn("very-secret-base64", str(result))
        self.assertEqual("new question", result[-1]["content"])


if __name__ == "__main__":
    unittest.main()
