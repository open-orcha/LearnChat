from __future__ import annotations

import hashlib
import secrets
from collections import deque
import hmac
import re
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Iterable, List, Optional, Protocol, Tuple


Message = Dict[str, Any]
ERASE_WAIT_SECONDS = 4.0


class CacheBackend(Protocol):
    def erase_slot(self, slot_id: int) -> bool: ...

    def save_slot(self, slot_id: int, filename: str) -> bool: ...

    def restore_slot(self, slot_id: int, filename: str) -> bool: ...

    def delete_snapshot(self, filename: str) -> None: ...


class SessionNotFound(Exception):
    pass


class SessionBusy(Exception):
    pass


class NoSlotAvailable(Exception):
    pass


class ContextTooLarge(Exception):
    pass


class CacheUnavailable(Exception):
    pass


def _plain_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: List[str] = []
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "text":
                parts.append(str(part.get("text", "")))
            elif part.get("type") in {"image", "image_url", "video"}:
                parts.append("[media]")
        return " ".join(parts)
    return str(content or "")


def estimate_message_tokens(messages: Iterable[Message]) -> int:
    total = 2
    for message in messages:
        text = _plain_content(message.get("content", ""))
        total += 5 + max(1, (len(text) + 3) // 4)
        images = message.get("images")
        if isinstance(images, list):
            total += 1024 * len(images)
        content = message.get("content")
        if isinstance(content, list):
            total += 1024 * sum(
                1 for part in content if isinstance(part, dict) and part.get("type") in {"image", "image_url", "video"}
            )
    return total


def compact_messages(messages: List[Message], target_tokens: int) -> List[Message]:
    """Deterministically summarize old turns and retain the newest complete turns."""
    clean = [dict(message) for message in messages]
    if estimate_message_tokens(clean) <= target_tokens:
        return clean

    system = [m for m in clean if m.get("role") == "system"][:1]
    turns = [m for m in clean if m.get("role") != "system"]
    recent: List[Message] = []
    recent_budget = max(64, int(target_tokens * 0.55))
    used = 0
    for message in reversed(turns):
        cost = estimate_message_tokens([message])
        if recent and used + cost > recent_budget:
            break
        recent.append(message)
        used += cost
    recent.reverse()
    old_count = max(0, len(turns) - len(recent))
    old = turns[:old_count]

    summary_lines: List[str] = []
    max_summary_chars = max(160, int(target_tokens * 4 * 0.28))
    for message in old:
        role = str(message.get("role", "unknown")).capitalize()
        text = re.sub(r"\s+", " ", _plain_content(message.get("content", ""))).strip()
        if not text:
            continue
        line = "- %s: %s" % (role, text[:240])
        if sum(len(item) + 1 for item in summary_lines) + len(line) > max_summary_chars:
            break
        summary_lines.append(line)
    summary = {
        "role": "system",
        "content": "Conversation summary (older turns compacted locally):\n" + ("\n".join(summary_lines) or "- Earlier context omitted."),
    }
    result = system + [summary] + recent

    # A final hard guard handles one exceptionally large recent message.
    while estimate_message_tokens(result) > target_tokens and len(recent) > 1:
        recent.pop(0)
        result = system + [summary] + recent
    if estimate_message_tokens(result) > target_tokens and recent:
        last = dict(recent[-1])
        content = _plain_content(last.get("content", ""))
        available_chars = max(64, int(target_tokens * 4 * 0.25))
        last["content"] = "[Earlier portion truncated during cache compaction]\n" + content[-available_chars:]
        last.pop("images", None)
        result = system + [summary] + [last]
    # Keep the configured bound absolute even when the original system prompt is unusually large.
    for _ in range(12):
        current = estimate_message_tokens(result)
        if current <= target_tokens:
            break
        candidates = [
            (len(_plain_content(message.get("content", ""))), index)
            for index, message in enumerate(result)
            if len(_plain_content(message.get("content", ""))) > 48
        ]
        if not candidates:
            break
        _, index = max(candidates)
        message = dict(result[index])
        content = _plain_content(message.get("content", ""))
        remove_chars = max(32, (current - target_tokens) * 4 + 8)
        if index == len(result) - 1:
            message["content"] = content[min(len(content), remove_chars) :]
        else:
            message["content"] = content[: max(32, len(content) - remove_chars)]
        message.pop("images", None)
        result[index] = message
    return result


def derive_session_id(secret: bytes, client_key: str, messages: List[Message]) -> str:
    anchor_parts: List[str] = []
    for message in messages:
        role = str(message.get("role", ""))
        if role not in {"system", "user"}:
            continue
        content = _plain_content(message.get("content", ""))
        image_digests = []
        for raw in message.get("images") or []:
            image_digests.append(hashlib.sha256(str(raw).encode("utf-8")).hexdigest())
        anchor_parts.append(role + "\0" + content + "\0" + ",".join(image_digests))
        if role == "user":
            break
    if not anchor_parts:
        anchor_parts.append("empty")
    raw = (client_key + "\0" + "\1".join(anchor_parts)).encode("utf-8")
    digest = hmac.new(secret, raw, hashlib.sha256).hexdigest()[:32]
    return "auto_" + digest


@dataclass
class Session:
    session_id: str
    created_at: float
    last_seen: float
    expires_at: float
    messages: List[Message] = field(default_factory=list)
    token_count: int = 0
    slot_id: Optional[int] = None
    cache_valid: bool = False
    in_flight: bool = False
    snapshot_filename: Optional[str] = None
    compactions: int = 0
    rebuilds: int = 0
    renewal_source: str = "request_started"
    prompt_limit: Optional[int] = None
    token_source: str = "estimated"


@dataclass(frozen=True)
class LeaseDecision:
    session_id: str
    slot_id: int
    messages: List[Message]
    token_count: int
    cache_reused: bool
    compacted: bool
    restored: bool


class SessionManager:
    def __init__(
        self,
        backend: CacheBackend,
        slots: int,
        lease_seconds: int,
        session_token_limit: int,
        total_cache_token_limit: int,
        snapshot_mode: str = "disabled",
        now: Callable[[], float] = time.time,
    ) -> None:
        self.backend = backend
        self.slot_count = slots
        self.lease_seconds = lease_seconds
        self.session_token_limit = session_token_limit
        self.total_cache_token_limit = total_cache_token_limit
        self.snapshot_mode = snapshot_mode
        self.now = now
        self.sessions: Dict[str, Session] = {}
        self.lock = threading.RLock()
        self.admission_paused = threading.Event()
        self.monitor_started_at = self.now()
        self.monitor_id = secrets.token_hex(16)
        # Public restart correlation must never disclose the conversation-alias key.
        self._monitor_alias_key = secrets.token_bytes(32)
        self.events = deque(maxlen=512)
        self.event_sequence = 0
        self.window_started_at = self.monitor_started_at
        self.window_id = secrets.token_hex(16)
        self.window_sequence = 0
        self.counter_baseline: Dict[str, int] = {}
        self.session_baseline: Dict[str, Tuple[int, int]] = {}
        self.record_event("runtime_started")
        self.counters: Dict[str, int] = {
            "cache_reuses": 0,
            "heartbeats": 0,
            "expirations": 0,
            "evictions": 0,
            "compactions": 0,
            "fallback_rebuilds": 0,
            "snapshot_saves": 0,
            "snapshot_restores": 0,
            "snapshot_failures": 0,
            "requests": 0,
            "request_errors": 0,
            "prompt_tokens": 0,
            "completion_tokens": 0,
        }

    def begin(
        self,
        session_id: str,
        messages: List[Message],
        token_count: int,
        prompt_token_limit: Optional[int] = None,
        token_counter: Optional[Callable[[List[Message]], int]] = None,
        token_source: str = "estimated",
    ) -> LeaseDecision:
        with self.lock:
            if self.admission_paused.is_set():
                raise CacheUnavailable("Backend paused for recovery; reload from the local dashboard.")
            now = self.now()
            self._expire_locked(now)
            session = self.sessions.get(session_id)
            if session is None:
                session = Session(session_id, now, now, now + self.lease_seconds)
                self.sessions[session_id] = session
            if session.in_flight:
                self.record_event("request_rejected", session_id, reason="session_busy")
                raise SessionBusy(session_id)

            session.last_seen = now
            session.expires_at = now + self.lease_seconds
            session.renewal_source = "request_started"
            session.token_source = token_source
            self.record_event("lease_renewed", session_id, reason="request_started", expires_at=session.expires_at)
            session.messages = [dict(message) for message in messages]
            session.token_count = max(0, token_count)
            compacted = False
            limit = min(
                self.session_token_limit,
                self.total_cache_token_limit,
                prompt_token_limit if prompt_token_limit is not None else self.session_token_limit,
            )
            session.prompt_limit = limit
            if limit < 32:
                raise ContextTooLarge("configured context leaves no usable prompt space")
            if session.token_count > limit:
                self.record_event("compaction_started", session_id, tokens=session.token_count, limit=limit)
                if session.slot_id is not None:
                    self._erase_slot(session)
                session.cache_valid = False
                session.snapshot_filename = None
                compact_target = max(32, int(limit * 0.82))
                real_to_estimated_ratio = max(
                    1.0,
                    session.token_count / max(1, estimate_message_tokens(session.messages)),
                )
                for _ in range(10):
                    estimated_target = max(32, int(compact_target / real_to_estimated_ratio))
                    candidate = compact_messages(session.messages, estimated_target)
                    candidate_tokens = (
                        max(0, token_counter(candidate)) if token_counter is not None else estimate_message_tokens(candidate)
                    )
                    session.messages = candidate
                    session.token_count = candidate_tokens
                    if candidate_tokens <= limit:
                        break
                    candidate_estimate = max(1, estimate_message_tokens(candidate))
                    real_to_estimated_ratio = max(
                        real_to_estimated_ratio,
                        candidate_tokens / candidate_estimate,
                    )
                    compact_target = max(32, int(compact_target * 0.72))
                if session.token_count > limit:
                    self.record_event("compaction_failed", session_id, reason="context_limit")
                    raise ContextTooLarge(
                        "conversation could not be compacted below the safe %d-token prompt limit" % limit
                    )
                session.compactions += 1
                session.rebuilds += 1
                self.counters["compactions"] += 1
                self.counters["fallback_rebuilds"] += 1
                compacted = True
                self.record_event("compaction_completed", session_id, tokens=session.token_count, limit=limit)

            restored = False
            if session.slot_id is None:
                slot_id = self._allocate_slot_locked(session)
                session.slot_id = slot_id
                if self.snapshot_mode == "best_effort" and session.snapshot_filename:
                    restored = self.backend.restore_slot(slot_id, session.snapshot_filename)
                    if restored:
                        session.cache_valid = True
                        self.counters["snapshot_restores"] += 1
                        self.record_event("snapshot_restored", session_id, slot=slot_id)
                    else:
                        session.cache_valid = False
                        session.rebuilds += 1
                        self.counters["snapshot_failures"] += 1
                        self.counters["fallback_rebuilds"] += 1
                        self.record_event("snapshot_failed", session_id, reason="restore")

            reused = session.cache_valid and not compacted
            if reused:
                self.counters["cache_reuses"] += 1
                self.record_event("cache_reused", session_id, slot=session.slot_id)
            else:
                self.record_event("cache_rebuild", session_id, reason="compaction" if compacted else "cache_unavailable", slot=session.slot_id)
            session.in_flight = True
            self.counters["requests"] += 1
            self._enforce_total_locked(exclude=session_id)
            assert session.slot_id is not None
            return LeaseDecision(
                session_id,
                session.slot_id,
                list(session.messages),
                session.token_count,
                reused,
                compacted,
                restored,
            )

    def finish(
        self,
        session_id: str,
        assistant_content: str,
        assistant_thinking: str,
        prompt_tokens: int,
        completion_tokens: int,
        success: bool,
        duration_ms: Optional[float] = None,
    ) -> None:
        with self.lock:
            session = self.sessions.get(session_id)
            if session is None:
                return
            session.in_flight = False
            now = self.now()
            if success:
                message: Message = {"role": "assistant", "content": assistant_content}
                if assistant_thinking:
                    message["reasoning_content"] = assistant_thinking
                session.messages.append(message)
                session.token_count = max(session.token_count, prompt_tokens) + max(0, completion_tokens)
                session.cache_valid = True
                session.last_seen = now
                session.expires_at = now + self.lease_seconds
                session.renewal_source = "request_completed"
                self.record_event("lease_renewed", session_id, reason="request_completed", expires_at=session.expires_at)
                self.record_event("request_completed", session_id, duration_ms=duration_ms)
                self.counters["prompt_tokens"] += max(0, prompt_tokens)
                self.counters["completion_tokens"] += max(0, completion_tokens)
            else:
                session.cache_valid = False
                self.counters["request_errors"] += 1
                self.record_event("request_failed", session_id, reason="backend_or_disconnect", duration_ms=duration_ms)
            self._enforce_total_locked(exclude=session_id)

    def heartbeat(self, session_id: str) -> Session:
        with self.lock:
            now = self.now()
            self._expire_locked(now)
            session = self.sessions.get(session_id)
            if session is None:
                self.record_event("heartbeat_rejected", session_id, reason="missing_or_expired")
                raise SessionNotFound(session_id)
            session.last_seen = now
            session.expires_at = now + self.lease_seconds
            session.renewal_source = "heartbeat"
            self.record_event("lease_renewed", session_id, reason="heartbeat", expires_at=session.expires_at)
            self.counters["heartbeats"] += 1
            return session

    def release(self, session_id: str) -> bool:
        with self.lock:
            session = self.sessions.get(session_id)
            if session is None:
                return False
            if session.in_flight:
                raise SessionBusy(session_id)
            self._release_session_locked(session, expired=False)
            return True

    def reap_expired(self) -> int:
        with self.lock:
            return self._expire_locked(self.now())

    def active_lease_count(self) -> int:
        with self.lock:
            now = self.now()
            return sum(1 for session in self.sessions.values() if session.in_flight or session.expires_at > now)

    def status(self) -> Dict[str, Any]:
        with self.lock:
            now = self.now()
            sessions = []
            for session in sorted(self.sessions.values(), key=lambda item: item.session_id):
                sessions.append(
                    {
                        "session": session.session_id[:13],
                        "lease_seconds_remaining": max(0, int(session.expires_at - now)),
                        "slot": session.slot_id,
                        "tokens": session.token_count,
                        "cache_valid": session.cache_valid,
                        "in_flight": session.in_flight,
                        "compactions": session.compactions,
                        "rebuilds": session.rebuilds,
                    }
                )
            return {
                "active_leases": self.active_lease_count(),
                "cached_tokens": sum(s.token_count for s in self.sessions.values() if s.slot_id is not None),
                "sessions": sessions,
                "counters": dict(self.counters),
            }

    def _allocate_slot_locked(self, session: Session) -> int:
        occupied = {item.slot_id for item in self.sessions.values() if item.slot_id is not None}
        for slot_id in range(self.slot_count):
            if slot_id not in occupied:
                return slot_id
        candidates = [
            item
            for item in self.sessions.values()
            if item.session_id != session.session_id and item.slot_id is not None and not item.in_flight
        ]
        if not candidates:
            self.record_event("request_rejected", session.session_id, reason="all_slots_busy")
            raise NoSlotAvailable("all llama.cpp slots are busy")
        victim = min(candidates, key=lambda item: (item.last_seen, item.session_id))
        assert victim.slot_id is not None
        slot_id = victim.slot_id
        self._evict_cache_locked(victim, "slot_pressure")
        return slot_id

    def _evict_cache_locked(self, session: Session, reason: str = "token_pressure") -> None:
        if session.slot_id is None:
            return
        if self.snapshot_mode == "best_effort" and session.cache_valid:
            filename = "session_%s_slot_%d.bin" % (hashlib.sha256(session.session_id.encode()).hexdigest()[:20], session.slot_id)
            if self.backend.save_slot(session.slot_id, filename):
                session.snapshot_filename = filename
                self.counters["snapshot_saves"] += 1
                self.record_event("snapshot_saved", session.session_id, slot=session.slot_id)
            else:
                session.snapshot_filename = None
                self.counters["snapshot_failures"] += 1
                self.record_event("snapshot_failed", session.session_id, reason="save")
        self._erase_slot(session)
        self.record_event("cache_evicted", session.session_id, reason=reason, slot=session.slot_id)
        session.slot_id = None
        session.cache_valid = False
        self.counters["evictions"] += 1

    def _enforce_total_locked(self, exclude: str) -> None:
        def total() -> int:
            return sum(item.token_count for item in self.sessions.values() if item.slot_id is not None)

        while total() > self.total_cache_token_limit:
            candidates = [
                item
                for item in self.sessions.values()
                if item.session_id != exclude and item.slot_id is not None and not item.in_flight
            ]
            if not candidates:
                return
            victim = min(candidates, key=lambda item: (item.last_seen, item.session_id))
            self._evict_cache_locked(victim)

    def _expire_locked(self, now: float) -> int:
        expired = [session for session in self.sessions.values() if not session.in_flight and session.expires_at <= now]
        for session in expired:
            self._release_session_locked(session, expired=True)
        return len(expired)

    def _release_session_locked(self, session: Session, expired: bool) -> None:
        if session.slot_id is not None:
            self._erase_slot(session)
        if session.snapshot_filename:
            self.backend.delete_snapshot(session.snapshot_filename)
        self.record_event("lease_expired" if expired else "lease_released", session.session_id, slot=session.slot_id)
        self.sessions.pop(session.session_id, None)
        self.session_baseline.pop(session.session_id, None)
        if expired:
            self.counters["expirations"] += 1

    def _erase_slot(self, session: Session) -> None:
        # Preserve the existing best-effort erase policy; only observe its result.
        if not self.backend.erase_slot(session.slot_id):
            self.record_event("cache_erase_failed", session.session_id, slot=session.slot_id)

    def session_ref(self, session_id: str) -> str:
        # Client-supplied IDs can contain private text. Never export them verbatim.
        return hmac.new(self._monitor_alias_key, session_id.encode(), hashlib.sha256).hexdigest()[:16]

    def reset_monitoring(self) -> None:
        """Change only the observation window, never operational accounting."""
        self.events.clear()
        self.event_sequence = 0
        self.window_started_at = self.now()
        self.window_id = secrets.token_hex(16)
        self.window_sequence += 1
        self.counter_baseline = dict(self.counters)
        self.session_baseline = {sid: (s.compactions, s.rebuilds) for sid, s in self.sessions.items()}

    def force_evict(self, target: str) -> Dict[str, Any]:
        # Caller holds lock; heartbeats/admission cannot race erasure. A heartbeat
        # only renews the lease and cannot restore an invalidated cache.
        chosen = list(self.sessions.values()) if target == "all" else [
            s for s in self.sessions.values() if self.session_ref(s.session_id) == target]
        if target != "all" and not chosen:
            raise SessionNotFound(target)
        if any(s.in_flight for s in chosen):
            raise SessionBusy("A selected conversation is busy. Wait, or unload all to interrupt it.")
        failed = []
        # Include unowned backend slots for an all-cache cold evaluation.
        slots = list(range(self.slot_count)) if target == "all" else [s.slot_id for s in chosen if s.slot_id is not None]
        deadline = time.monotonic() + 15.0
        for index, slot in enumerate(slots):
            # A socket timeout alone is not a total deadline (a peer can trickle
            # bytes). One bounded worker allows unload recovery even then.
            done = threading.Event()
            outcome = []
            def erase(slot=slot, done=done, outcome=outcome):
                try:
                    outcome.append(self.backend.erase_slot(slot))
                except Exception:
                    outcome.append(False)
                finally:
                    done.set()
            threading.Thread(target=erase, daemon=True).start()
            if not done.wait(max(0, min(ERASE_WAIT_SECONDS, deadline - time.monotonic()))) or not outcome or not outcome[0]:
                failed.extend(slots[index:])
                break
        for s in chosen:
            if s.snapshot_filename:
                self.backend.delete_snapshot(s.snapshot_filename)
                s.snapshot_filename = None
            s.cache_valid = False
            if s.slot_id in failed:
                self.record_event("cache_erase_failed", s.session_id, slot=s.slot_id)
                # Keep ownership on failure: do not advertise freed capacity.
                continue
            s.slot_id = None
            self.counters["evictions"] += 1
            self.record_event("cache_evicted", s.session_id, reason="manual")
        return {"ok": not failed, "failed_slots": failed, "affected_conversations": len(chosen),
                "message": "Cache erased. The next chat rebuilds from phone history; RAM release is not guaranteed." if not failed else
                "Cache erasure failed or timed out. Capacity was not claimed as freed for failed slots. Use unload and pause for recovery."}

    def backend_unloaded(self) -> None:
        for s in self.sessions.values():
            if s.snapshot_filename:
                self.backend.delete_snapshot(s.snapshot_filename)
            s.snapshot_filename = None
            s.slot_id = None
            s.cache_valid = False
        self.record_event("backend_unloaded", reason="manual")

    def record_event(self, kind: str, session_id: Optional[str] = None, reason: Optional[str] = None, **numbers: Any) -> None:
        with self.lock:
            self.event_sequence += 1
            event = {"sequence": self.event_sequence, "at": self.now(), "kind": kind}
            if session_id is not None:
                event["session"] = self.session_ref(session_id)
            if reason:
                event["reason"] = reason
            # Only explicitly named numeric fields; never messages or exception text.
            for key in ("expires_at", "tokens", "limit", "slot", "duration_ms"):
                value = numbers.get(key)
                if isinstance(value, (int, float)):
                    event[key] = value
            self.events.append(event)

    def monitor_snapshot(self) -> Dict[str, Any]:
        """Read-only snapshot. Does not expire, renew, allocate, or touch the backend."""
        with self.lock:
            now = self.now()
            sessions = []
            # Bound export size even if callers create many evicted leases.
            for session in self.sessions.values():
                if len(sessions) == 256:
                    break
                sessions.append({
                    "session": self.session_ref(session.session_id),
                    "created_at": session.created_at,
                    "expires_at": session.expires_at,
                    "last_renewal_at": session.last_seen,
                    "renewal_source": session.renewal_source,
                    "state": "busy" if session.in_flight else "active" if session.expires_at > now else "awaiting_expiry",
                    "slot": session.slot_id, "tokens": session.token_count,
                    "token_source": session.token_source,
                    "prompt_limit": session.prompt_limit,
                    "cache_valid": session.cache_valid, "in_flight": session.in_flight,
                    "compactions": session.compactions - self.session_baseline.get(session.session_id, (0, 0))[0],
                    "rebuilds": session.rebuilds - self.session_baseline.get(session.session_id, (0, 0))[1],
                    "snapshot_available": bool(session.snapshot_filename),
                })
            occupied = sum(s.slot_id is not None for s in self.sessions.values())
            return {
                "boot_id": self.monitor_id, "started_at": self.monitor_started_at,
                "window_id": self.window_id, "window_started_at": self.window_started_at,
                "window_sequence": self.window_sequence,
                "sampled_at": now, "sessions": sessions,
                "session_count": len(self.sessions), "sessions_omitted": max(0, len(self.sessions) - len(sessions)),
                "active_leases": self.active_lease_count(),
                "cached_tokens": sum(s.token_count for s in self.sessions.values() if s.slot_id is not None),
                "slots_occupied": occupied, "slots_free": self.slot_count - occupied,
                "slots_busy": sum(s.in_flight for s in self.sessions.values()),
                "counters": {k: v - self.counter_baseline.get(k, 0) for k, v in self.counters.items()}, "events": list(self.events),
                "event_capacity": self.events.maxlen, "event_sequence": self.event_sequence,
                "events_dropped": max(0, self.event_sequence - len(self.events)),
            }
