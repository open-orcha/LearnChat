# Local runtime dashboard

Open **http://127.0.0.1:11436/** on the Mac that runs Muse Glimmer. The page refreshes every
two seconds and remains available after the worker or terminal exits. It is deliberately
not accessible from a phone or another computer.

From the repository root, using Python 3.9+ with psutil installed:

```sh
python3 -m pip install -r muse-runtime/requirements-monitor.txt
python3 muse-runtime/scripts/dashboard.py start
python3 muse-runtime/scripts/dashboard.py status
python3 muse-runtime/scripts/dashboard.py stop
```

Only the dashboard needs psutil (validated here with 5.9.5). The inference service still
uses the Python standard library. Choose the same Python executable for installation and
these commands. If you use a virtual environment, keep it outside disposable worktrees.
The start command registers `local.muse-glimmer.dashboard` with macOS launchd in the current
user's GUI session; launchd restarts a crashed dashboard. Stopping it leaves chat running.
Run `start` again after logout or reboot; this does not install a login item. An already
registered dashboard is left running. After changing dashboard source, stop/start it to
load the change. Keep the checkout in place while its service runs.

For a custom `MUSE_STATE_DIR`, pass the same absolute path with `--state-dir /your/path` to
`start`. The control script also honors an exported `MUSE_STATE_DIR`; it does not source
`.env`. Default state is `muse-runtime/state/`. The runtime and dashboard must read/write the
same directory. The dashboard's registered job uses the selected path on subsequent starts.

## Activate telemetry once

The instrumented runtime writes `state/monitor.json`. Deploying new runtime code requires
one **coordinated** restart: finish phone/QA tests, check `/api/status` for no active leases
or in-flight sessions, and then use `muse-runtime/scripts/stop.sh` and `start.sh` from the
canonical checkout. Do not restart during a chat. The restart loses existing in-memory
leases, cache contents and previous event history. No model, lease or network settings
need to change. Subsequent dashboard starts/stops never restart the runtime.

## What the page means

- **Host RAM:** total minus available bytes, displayed in GiB (1 GiB = 1,073,741,824 bytes).
  Available memory is OS-reported reclaimable headroom, not a promised allocation. Swap is
  shown separately. Host CPU is 0–100% across all logical CPUs.
- **Process use:** model, Python chat service and dashboard RSS (resident memory), and CPU
  where 100% means one logical CPU. A multithreaded process can exceed 100%. The first CPU
  sample needs a second observation. Process RSS can overlap shared pages and does not
  isolate Apple unified-memory GPU buffers or KV cache allocations. Missing measurements
  are labeled unavailable. An externally managed backend has no supervised PID to measure.
- **Leases:** last successful renewal and its source, expiry time, remaining time and busy
  state. Chat admission, successful reply completion and app heartbeats renew the existing
  lease; page views do not. An idle lease expires on the next one-second reaper sweep.
  A request in flight is protected beyond its nominal expiry until it finishes.
- **Context and cache:** configured per-session, per-slot and total context limits are
  distinct. A chat's output budget is reserved inside the slot; the safe prompt budget is
  `min(session limit, slot context − requested/clamped output budget)`. Long prompts are
  compacted and rebuilt. The last prompt budget is shown per session. Tracked tokens use
  backend tokenization when available, with estimation as a fallback; even tokenizer-based
  counts are not exact physical KV bytes or proof of prefix reuse.
- **Pressure:** least recently used idle caches can be evicted when all slots are occupied
  or the total cached-token target is exceeded. Leases may survive that eviction and their
  next chat rebuilds from supplied history. Busy/current work is excluded from eviction,
  so the total may temporarily exceed the target. There is no fixed pressure countdown
  and no configured RAM-byte eviction threshold. Erase failures are reported separately:
  slot accounting describes the runtime's logical state, not a physical-memory guarantee.
- **Model lifetime:** the configured weight-unload policy is independent of leases. Under
  `keep_loaded`, model weights stay loaded even with no sessions. Under other policies,
  monitoring does not reset idle activity or load the model. Readiness is a health read,
  not proof that a phone chat succeeded.
- **Events:** every instrumented renewal is recorded, including repeated renewals between
  dashboard samples. Expiry, release, pressure reason, compaction, rebuild, snapshot failures,
  request failure/disconnection and backend readiness changes are correlated by private
  conversation alias. Rebuild events describe the requested operation; reply completion
  confirms completion of the request. Latency averages cover successful replies retained
  in the bounded event history, not all historical traffic. Displayed counters cover the current observation window; operational counters remain unchanged by a dashboard reset.

## Bounds, freshness and privacy

The runtime retains **512 events in memory**, exports at most **256 session rows**, and
atomically replaces one private mode-0600 snapshot every two seconds. The export is capped
at 2 MiB. Counters and omission/drop counts remain visible. The separate dashboard retains
**90 host samples** (about three minutes) and keeps one latest runtime snapshot. Additional
browser tabs read that same sample; they do not multiply backend sampling. The dashboard
uses separate HTTP workers with a two-second request-body socket timeout, so a control cannot block monitoring. Only one control runs at a time. There are no access logs,
external fonts, analytics, CDNs or browser storage.

A runtime snapshot older than eight seconds, a missing producer process, a missing/corrupt
file or a failed browser fetch is visibly stale/disconnected. Lease countdowns freeze at the
last observed state; old data never confirms that a lease is still alive. Host resources may
continue updating while runtime data is stale. History starts at runtime startup or the latest manual reset and rolls
over at 512 events. Observed restarts are marked, but this is not a durable audit log: events
before startup, after an unobserved crash, or rolled out of the buffer are unavailable.
Timestamps use the Mac's clock and are displayed in the browser's time zone.

Telemetry is exported from explicit metadata fields only. Prompts, responses, reasoning,
attachments, API keys, original client session IDs, paths and exception bodies are excluded.
Conversation aliases use a private random per-runtime HMAC key, independent of the public
restart identifier, and change on restart. The key is never exported. The dashboard
binds only `127.0.0.1`; it checks Host/Origin, rejects cross-site telemetry requests, has no CORS grant,
and serves three static assets, `/api/monitor`, and protected `POST /api/control`. Links may open the static
page as a top-level document; no telemetry is embedded in that HTML. It never calls the phone
HTTP API. Mutations require an exact same-origin Origin header, JSON content type and a random dashboard token obtained from protected telemetry; cross-site requests are rejected. The dashboard forwards commands to a separate ephemeral loopback listener authenticated by a private mode-0600 `state/control.json` credential. That listener rejects browser Origins. No control routes are added to the phone API. Same-user local programs are trusted. The existing public status endpoint is unchanged; renewal events are not added to it.


## Reset and cache controls

**Reset dashboard data** clears retained runtime events and host chart samples, and establishes
an observation window whose start is shown on the page. Displayed request/renewal/cache and
per-conversation compaction/rebuild totals start at zero. Operational totals, uptime, live RAM/CPU,
current sessions, lease deadlines, cache contents and configured policy are preserved. Reset
works during a reply. A completion observed after reset belongs to the new window, even if
that request began earlier. Other open tabs pick up the new window on polling. Old snapshots
are withheld until the exporter publishes the new window, so old events cannot return.
Each runtime start allocates an increasing producer number in the private state directory;
reset replies and telemetry carry that number plus the window sequence. Both collector and
browser retain the newest accepted pair, rejecting earlier producers even before the new
runtime's first export or when a pre-reset HTTP response arrives late. A genuinely later
restart/reset is accepted without relying on wall-clock order. Keep `monitor-generation`
with the runtime state; deleting it while dashboard tabs remain open requires reopening those
tabs. Counter allocation uses a private atomic file and a nonblocking startup lock; a corrupt
counter or lock conflict fails startup visibly rather than inventing an ordering.
A disconnected runtime makes reset fail visibly; it cannot pretend to clear remote history.
History remains bounded to 512 events / 90 resource samples. Nothing deletes phone chat history.

**Force evict KV cache** requires a target: one conversation alias or **All caches**. Selected
eviction leaves other sessions' cache contents alone. All caches also erases unowned backend
slots. Disk snapshots referenced by the selected sessions are invalidated, so they cannot
restore a supposedly cold cache. Leases and conversation messages survive; heartbeats only
renew leases and do not reload a cache. The next chat submits its phone history with backend
prompt reuse disabled for the cold request, then resumes normal reuse after success.

Eviction refuses while any chat request is active (including admission/tokenization), so it
cannot silently interrupt a stream. Heartbeats and new chat admission serialize against the
operation. For a reproducible cold-cache evaluation, evict after a reply completes, then send
one new chat request with its previous history. Check the cache rebuild event and the response's
`cache_reused: false`. This is a context-cache evaluation, not a cold model-weight benchmark.

Erasure has a 3-second socket timeout, a 4-second total wait per slot and a 15-second total
operation budget. A failed/timed-out erase preserves failed slot ownership and reports failure;
new chat admissions then stay blocked until unload/reload because a backend erase might still
be pending. A concurrent control fails immediately. A busy manager has a 2-second acquisition
limit. The page keeps polling throughout; bridge/browser waits are 60/65 seconds and report
an unknown outcome on lost connection, never assumed success. Refresh state before retrying.

Expand **Stuck backend or need to release model memory?** and acknowledge the interruption to
use **Unload model and pause chats**. It stops only the supervised llama.cpp process (5 seconds
for termination, then 3 seconds for forced kill), which interrupts all affected replies and
releases that process's allocations, including model weights. It does not delete phone history.
An externally managed backend is not killed; the result explains that limitation. Failure to
stop or finish bookkeeping is shown as failure; retry unload before reloading. Interrupted
request handlers must drain before **Reload model** is accepted. Reload has a 45-second readiness
budget; a failed reload stops and pauses the backend again.

If no supervised process exists (before first load, after idle unload, or after restoring a
manual pause), unload reports that no memory release occurred and leaves explicit reload
available. Repeating unload after a successful stop does not claim another memory release.
An existing failed-erasure quarantine is preserved: an empty/unmanaged backend cannot be
used to bypass the required stop and recovery. Unload never waits on a health probe to decide
whether it owns a process.

Health probes run outside the process lifecycle lock, wait at most 2.5 seconds in total, and
allow at most one outstanding probe. Unload also closes admitted client connections, including
partial uploads and readers stalled on a stream. Request bodies have a 10-second total upload
deadline; client socket writes have a 10-second timeout. New work cannot reach a reloaded
backend until the interrupted handlers have drained.

Manual pause is stored in `state/backend-paused`, so health checks, heartbeats, new phone chats,
and even runtime restarts cannot silently reload it. Phone chat requests receive a clear
unavailable error until **Reload model** succeeds. Normal health polling and heartbeat behavior
remain passive. Deleting the pause file manually is unnecessary; use the control. The existing
shell start script expects readiness and should not be used to clear a deliberate pause.

### What memory release means

The installed llama.cpp reports version 0.7.0 / build 11669. Its
[sequence removal implementation](https://github.com/ggml-org/llama.cpp/blob/620d2225c/src/llama-kv-cache.cpp)
changes cache-cell ownership without destroying the backing buffers. Slot erasure may therefore
free logical capacity while process RSS barely changes. It is not proof that memory returned
to macOS. Unloading the supervised process ends its allocations, but host available RAM can
also move because of other apps, compressed memory and reclaimable file pages.

Every control displays timestamped before/after host RAM and supervised model RSS. Missing
measurements are labeled unavailable; no remaining supervised process is labeled explicitly,
not reported as a measured zero. RSS includes more than KV and cannot isolate Apple unified
GPU allocations. Compare measured values and process disappearance, never just token counters.
Live validation results and observed memory deltas are recorded in the task report.

On October 17, 2026, isolated checks against the running model confirmed selected-slot
prompt tokens fell from 165 to zero while the other slot stayed at 147. A heartbeat did
not rebuild the erased cache; the next reply correctly recovered earlier facts with
`cache_reused: false`, while the untouched conversation returned `true`. All-cache erasure
also cleared both populated slots without losing the supplied conversation history.

The dashboard measured model RSS at 18.05 GiB before and after selected erasure, and
18.10 GiB before and after all-cache erasure (rounded display values). During an active
test reply, unload removed the supervised process that had reported 18.12 GiB RSS;
host RAM in use moved from 85.06 to 79.59 GiB in the immediate observations. These are
observations of the whole Mac, not a measurement of exactly how many KV bytes were freed.
Health checks, a heartbeat and a rejected new chat left the model paused. Explicit
reload took about four seconds, and a subsequent cold reply recovered the earlier facts.
The isolated leases were removed and ready service restored. These checks are not phone
acceptance; QA review and Kedar's separate verification remain required.

## Checks

```sh
python3 -c 'import sys, psutil; print(sys.executable, psutil.__version__)'
PYTHONPATH=muse-runtime python3 -m unittest discover -s muse-runtime/tests -v
node muse-runtime/tests/test_dashboard_polling.js
node --check muse-runtime/muse_runtime/dashboard_assets/dashboard.js
```

Use the same Python with psutil installed as for the dashboard launch. The standard-library
runtime suite can also run without psutil: the producer-process liveness check is explicitly
skipped and a separate test covers unavailable resource measurements and freshness-only
status. That mode is not full resource-monitoring validation.

Use isolated conversation IDs for real runtime checks. Confirm chat start/completion and
heartbeat renewals appear, then leave the page open for longer than the configured lease
without further heartbeats; the session must expire. Confirm repeated page/API refreshes
leave the heartbeat counter and expiry unchanged. Use an isolated manager/fake backend for
slot-pressure, compaction, error and history-bound checks; never evict a person's live chat
for a dashboard test. Browser QA should cover empty/active states, filtering, small screens,
frozen stale/disconnected state and recovery. Physical phone acceptance remains a separate
human check.
