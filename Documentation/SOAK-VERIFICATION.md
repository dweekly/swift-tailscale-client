# Soak Verification Protocol and Test Record

**Related plan sections:** `Documentation/PLAN-1.0.md § W9 & § 5`, `Documentation/DECISIONS-1.0.md` (Decision 3)  
**Components under test:** `IPNBusBoundedQueue`, `TailscaleClient.watchIPNBusEvents`, `StreamingResponse`, `UnixSocketTransport`

---

## 1. Summary

This document describes how `swift-tailscale-client` is soak-tested for memory, descriptor, and reconnect stability under continuous streaming, and records the soak runs that have actually been measured.

| Run | Status | Result |
|---|---|---|
| Short synthetic fault soak (30 seconds), 2026-09-18 | Measured locally | 5,271 notifications processed; peak RSS 15,072 KiB; zero net file and socket descriptor growth. |
| 1-hour synthetic soak | **Not yet run** | No report exists. |
| 24-hour live-daemon soak | **Not yet run** | No report exists. |

The 30-second run is a local working-tree result, not exact-tag qualification, and it does not satisfy the long-soak gate in `Documentation/PLAN-1.0.md` (W9). The 1.0.0 release shipped with the long soaks open; see [`Documentation/releases/1.0.0.md`](releases/1.0.0.md) and the 1.0.0 "Validation and limitations" section of `CHANGELOG.md`.

Soak reports are written as `soak-report-*.json` files, which are gitignored. A run counts as evidence only when its report is attached to the release record or PR that cites it.

---

## 2. Streaming design under stress

These are the behaviors a soak run exercises. They are defined in source; file paths below are relative to `Sources/TailscaleClient/`.

### 2.1 Bounded queue (`IPNBusBoundedQueue`)

`watchIPNBusEvents` buffers events for a slow consumer in `IPNBusBoundedQueue` (`Support/IPNBusBoundedQueue.swift`), limited by `StreamBufferBounds` (`Models/StreamBufferBounds.swift`):

- Default limits: 256 queued events and 16,777,216 bytes (16 MiB) of retained payload. Callers can pass other limits, including `StreamBufferBounds.unbounded`.
- An event that would push the queue past either limit triggers overflow handling:
  - `.reportGap` (default): the buffered events are discarded, the byte counter resets, and the consumer receives `IPNBusEvent.lifecycle(.stateGap(reason: "buffer_overflow"))`. The incoming event is kept if it fits within the byte limit on its own.
  - `.fail`: the buffer is cleared and the stream throws `TailscaleClientError.streamOverflow`.
- Below the queue, the transport applies its own limits: `NewlineFramer` rejects lines over 4 MiB (`Transport/HTTPWireFormat.swift`), and `TransportByteBoundedQueue` pauses socket reads at 256 KiB buffered and fails at 16 MiB (`Transport/TransportByteBoundedQueue.swift`).

With the default bounds, retained queue payload therefore stays at or under 16 MiB. That is a property of the code and its unit tests; no soak run has measured internal queue depth (see section 3.3).

### 2.2 Event classification (`IPNBusEvent`)

- `.notification(IPNNotify)`: daemon state updates (netmap, peers, health, routes).
- `.lifecycle(IPNBusLifecycle)`: connection transitions (`.connected`, `.disconnected(underlying:)`, `.retrying(attempt:delay:)`, `.stateGap(reason:)`).

Consumers can see disconnects and retries without mistaking them for changes in daemon state.

### 2.3 Reconnect backoff

`StreamRetryPolicy.default` (`Models/StreamRetryPolicy.swift`) retries indefinitely with:

- Base delay `min(100 ms × 2^attempt, 10 s)` for a 0-indexed attempt.
- ±20% proportional jitter, so the first retry waits at least 80 ms.
- Errors that `StreamRetryPolicy.classify(_:)` marks fatal (for example `permissionDenied`, `streamOverflow`, decoding errors, cancellation) stop retrying immediately.
- If opening the stream returns HTTP 401, or 403 on a non-Unix-socket endpoint, a client with automatic endpoint discovery rediscovers credentials once and reopens the stream (`TailscaleClient.swift`).

### 2.4 Recovering from a state gap

When a consumer receives `.lifecycle(.stateGap(reason:))`, it should treat cached peer and status data as stale and re-fetch a baseline with `status()` before applying further deltas. This is consumer behavior; the soak harness counts the gap events but cannot observe whether a consumer refreshed.

---

## 3. Soak harness (`Scripts/run-soak-verification.py`)

### 3.1 What it does

- Builds `tailscale-swift` and records the binary's SHA-256.
- Launches `tailscale-swift watch --json --events --reconnect` as a child process and reads its JSON event stream.
- With `--target synthetic_fault_server` (default), serves a synthetic LocalAPI on a temporary Unix socket that streams about 200 notifications per second. Every 3 seconds it injects one randomly chosen fault: a forced disconnect, an unthrottled burst of 300 notifications, or an undecodable line.
- With `--target live_localapi`, the child process discovers and watches the local tailscaled instead.
- Samples the child's RSS and its open file and socket descriptor counts (`proc_pidinfo` through `libproc` on Darwin, `/proc/<pid>/fd` on Linux) at each sample interval and once before teardown.

### 3.2 Modes and defaults

| Option | Default |
|---|---|
| `--mode accelerated` | 15-second run, 2-second sample interval |
| `--mode extended` | 3,600-second run, 10-second sample interval |
| `--duration-seconds N` | Overrides the run length |
| `--output PATH` | Report path (default `soak-report-<UTC timestamp>.json`) |

### 3.3 Verdict

A run fails if any of the following is true:

- The child process exits before the run ends.
- Any RSS or descriptor measurement is unavailable.
- Fewer than three RSS samples were taken, or RSS grew by more than 32,768 KiB across the last three samples.
- Net file or socket descriptor growth from baseline to final exceeds 1.
- No notifications were processed.

The report also counts disconnects, retries, the longest observed retry delay, and state gaps by reason. These fields are written as `null` because an external process cannot observe them: queue high-water marks, `queue_ceiling_breached`, `tight_loop_detected`, `baseline_refreshes_executed`, and `cache_inconsistencies`.

`Scripts/test-soak-verification.py` runs the harness against simulated measurements to confirm that each failure condition above produces a failing verdict. CI runs it in the "Docs consistency" job. CI does not run a soak.

---

## 4. Measured runs

### 4.1 Short synthetic fault soak — 2026-09-18

- Target: `synthetic_fault_server`, local working tree, 30 seconds.
- 5,271 notifications processed.
- Peak RSS 15,072 KiB.
- Zero net file and socket descriptor growth.

The report file for this run is not committed. The figures above are the ones recorded in [`Documentation/releases/1.0.0.md` § 3](releases/1.0.0.md#3-focused-remediation--2026-09-18).

### 4.2 Not yet run

- **1-hour synthetic soak:**
  ```bash
  python3 Scripts/run-soak-verification.py --mode extended --duration-seconds 3600 --output soak-report-1h.json
  ```
- **24-hour live-daemon soak** (needs a running, logged-in tailscaled; run under `caffeinate -is` on a Mac that sleeps):
  ```bash
  python3 Scripts/run-soak-verification.py --mode extended --target live_localapi --duration-seconds 86400 --output soak-report-24h.json
  ```

When a long run completes, add its date, commit, platform, and headline figures to this section and attach the report to the PR or release that cites it.

---

## 5. Report format

Each report is a JSON object with these top-level keys, all written by `run_soak_test` in `Scripts/run-soak-verification.py`:

| Key | Contents |
|---|---|
| `schema_version` | `"1.0.0"` |
| `generated_at` | UTC timestamp of report generation |
| `process` | Child binary name, path, SHA-256, PID, platform |
| `configuration` | Mode, target, measured duration, sample interval, toolchain, platform |
| `event_volume` | Total, notification, and lifecycle event counts; events per second; bytes received; average event size |
| `memory_bounds` | Baseline, peak, and final RSS (KiB); `plateau_reached`; configured queue ceilings (256 events, 16,777,216 bytes); queue high-water marks (`null`, unmeasured) |
| `reconnect_and_backoff` | Disconnects, reconnects, retry attempts, longest retry delay (ms); `tight_loop_detected` (`null`, unmeasured) |
| `state_gap_recovery` | State-gap counts by reason (`reconnected`, `buffer_overflow`, `undecodable_line`); baseline-refresh and cache fields (`null`, unmeasured) |
| `resource_leak_audit` | Baseline, peak, and final file and socket descriptor counts; net growth |
| `verdict` | `passed` and the list of `violations` |

---

## 6. How to run

1. Accelerated run (15 seconds by default):
   ```bash
   python3 Scripts/run-soak-verification.py --mode accelerated
   ```
   Exits non-zero if any section 3.3 condition fails.

2. Harness self-test (what CI runs):
   ```bash
   python3 Scripts/test-soak-verification.py
   ```

3. Long runs: the commands in section 4.2.

4. Mock-transport unit tests named for soak scenarios (burst traffic, task accumulation, connection churn). These run against `MockTransport` and do not measure process memory or descriptors:
   ```bash
   swift test --filter Tier1FeatureTests/test_feat35
   ```
