# Runtime HTTP contract

All routes below are on the Python service, normally port 11434. The internal llama.cpp
backend stays at `127.0.0.1:18080`. These are the public routes used by LearnChat and local operations.
See [setup](setup-runtime.md) for configuration and [troubleshooting](troubleshooting.md) for
common failures. When configured, protected calls require `Authorization: Bearer <key>`.

| Method and route | Meaning |
| --- | --- |
| `GET /healthz` | Backend readiness probe; does not prove a completed chat |
| `GET /api/tags` | One advertised configured model |
| `GET /api/status` | Readiness, model lifetime, cache/lease summaries and counters |
| `GET /metrics` | Prometheus aggregate counters |
| `POST /api/chat` | Muse Glimmer chat; streaming or non-streaming |
| `POST /api/sessions/{id}/heartbeat` | Renew an existing session lease |
| `DELETE /api/sessions/{id}` | Release an idle session/cache |

## Chat and IDs

`POST /api/chat` accepts `model`, `messages`, `stream`, `think`, `options.num_ctx`,
`options.num_predict`, and base64 `images` on messages. The configured backend limits take
precedence over requested context sizes. The request's model label does not select another
backend; there is one loaded model.

Supply an opaque, stable per-conversation ID in `session_id` or `X-Muse-Session-ID`.
A nonempty body ID takes precedence over the header. The reply includes the ID in the header
and JSON chunks. When no ID is supplied, the server derives a keyed ID from caller/opening-turn
information. This compatibility fallback is not a substitute for explicit client IDs.

A streaming response uses `application/x-ndjson` newline-delimited JSON, not SSE.
`message.content` is answer text and `message.thinking` is optional reasoning; the final chunk has
`done: true`. Inspect `error`
before declaring success, including errors arriving after HTTP 200. A `done_reason` of
`length` means output was limited. `think:false` hides reasoning output, not necessarily
model reasoning time.

## Leases and recovery

After a successful chat, renew while the conversation remains visible and the app is in the
foreground. Android does this approximately every 120 seconds for a 300-second lease.
New empty chats need no heartbeat. Stop renewal on background/navigation and let expiry occur.
The next chat must include sufficient local context to recover after expiry or server restart.

Heartbeat success is `{"session_id":"...","lease_expires_at":"<UTC ISO-8601 timestamp>","lease_seconds":300}`.
HTTP 404 with `{"error":"session not found or expired"}` means no live session exists.
Keep local history and the same ID; the next full-context chat recreates it. Heartbeat success
does not mean an in-flight generation has ended. DELETE returns `{"released":true}` or
404 with `{"released":false}`; it cannot cancel active generation and may return 409.

| Response | Client action |
| --- | --- |
| 400 | Correct invalid input or reduce an unfit request; do not retry unchanged forever |
| 401 | Fix the configured API credential/header |
| 404 heartbeat | Retain local history; recreate with the next chat |
| 409 chat | Same session still generating; briefly delay before retrying |
| 503 | All available slots busy or backend unavailable; show failure/retry later |

For cancellation followed by resend, Android retries HTTP 409 before any stream events at
250, 500, 1000, 2000 and 2000 ms, then reports failure. This finite budget is not a guarantee
that a hidden-reasoning generation has stopped. Do not retry after partial output as though
nothing was received, or duplicate the user's local message. Do not delete server sessions
on every screen transition.

## Cache management and privacy

Four slots share a 32768-token allocation: 8192 per slot. The service reserves output budget
inside each slot, compacts older turns when needed, recounts with the backend tokenizer and
fails cleanly if the request still cannot fit. Local phone history remains the recovery source;
compaction is lossy and is not permanent memory. A global 24576-token cache bound may evict the
least-recently-used idle slot while retaining session state for rebuilding.

Active requests cannot expire or be evicted. Idle lease expiry erases the slot. Model weights
have a separate lifetime and stay loaded with `keep_loaded`. Slot snapshots remain disabled
because this hybrid model's restore behavior has limitations; best-effort snapshots can contain
conversation-derived data and must never enter Git.

Status reports shortened opaque IDs, remaining lease time, token counts, slots and counters;
it does not return chat messages. Runtime state and logs are nevertheless local-only. Metrics
include `muse_active_leases`, `muse_cached_tokens`, and totals for cache reuse, heartbeats,
expirations, evictions, compactions and fallback rebuilds.
