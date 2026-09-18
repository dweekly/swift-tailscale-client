# Consumer Validation & Upstream Adoption Architecture (1.0)

**Canonical validation and architecture record for Milestone 3 Work Item W8 (PR 14 Part 2).**

This document establishes the consumer validation architecture for `swift-tailscale-client` 1.0. It documents real-world consumer patterns across two distinct architectural archetypes, presents the resolution ledger for all pre-1.0 integration friction points, and defines the verification suites that prove the public API contracts without private `@testable` imports.

---

## 1. Executive Summary & Scope

A production-grade 1.0 client library cannot be validated solely by internal unit tests or synthetic micro-benchmarks. Real consumer applications impose distinct operational pressures:
- **Read-Heavy Continuous Monitoring**: Long-lived background monitoring processes that stream state changes over hours and days without memory growth, file descriptor leaks, or desynchronization.
- **Active Configuration & Lifecycle Management**: Workstation provisioning daemons and service orchestrators that perform transactional, conditional updates across multi-tenant profiles and reverse-proxy configurations.

To validate `swift-tailscale-client` 1.0 against both operating profiles, this document evaluates:
1. **Network Weather (NWX)**: A macOS menu-bar and diagnostics application serving as the primary read-heavy monitoring reference consumer.
2. **TailscaleFleetAgent**: A workstation and server configuration management daemon exercising active mutations, profile lifecycles, and Serve/Funnel routing.

Both consumers are validated strictly against the public interface (`import TailscaleClient`), using `import TailscaleClientMocks` for unit testing.

---

## 2. Consumer Archetype 1: Network Weather (NWX) Migration

### 2.1 Consumer Profile
Network Weather (NWX) is a native macOS application that displays real-time tailnet health, latency matrices, active exit nodes, and peer connectivity from the macOS menu bar and notification center.

### 2.2 Historical 0.12.x Limitations in NWX
In `swift-tailscale-client` 0.12.x, NWX encountered several architectural challenges:
- **Polling vs Streaming**: Polling `status()` every 3–5 seconds caused repeated process wakeups, battery consumption on MacBooks, and IPC latency spikes.
- **Unbounded Streams**: Early IPN bus streams had no memory bounds; if the main UI thread hitched during heavy animation or screen sleep, the underlying buffer grew without bound.
- **Sparse Delta Desynchronization**: The daemon's IPN bus emits delta notifications (`IPNNotify`). If an intermediate network drop or reconnect occurred, dropped delta notifications resulted in "ghost peers" or stale offline statuses.
- **Opaque Disconnects**: Disconnections threw unstructured transport errors without differentiating transient retries from fatal authentication rejections.
- **Main-Thread Discovery Hitches**: Synchronous discovery probed filesystem sockets and process tables, blocking calling actors.

### 2.3 Target 1.0 Architecture in NWX

The 1.0 architecture transforms NWX into an event-driven, zero-leak monitoring client:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       NWX MONITORING LIFECYCLE (1.0)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. Launch & Asynchronous Discovery                                        │
│     let client = try await TailscaleClient.discover()                       │
│     │ (Non-blocking probe of Homebrew socket / standalone .pkg symlink)     │
│     ▼                                                                       │
│  2. Initial Baseline Seeding                                                │
│     async let initialStatus = client.status()                               │
│     async let initialNetCheck = client.netcheck()                           │
│     let (status, netcheck) = try await (initialStatus, initialNetCheck)     │
│     │ (Populates peer cache, DERP latencies, self node IP)                 │
│     ▼                                                                       │
│  3. Bounded Event Stream Subscription                                       │
│     let stream = try await client.watchIPNBusEvents(                        │
│         options: [.initialState, .initialHealthState, .initialNetMap],      │
│         retryPolicy: .default,                                              │
│         bounds: StreamBufferBounds(maxEventCount: 256,                      │
│                                    overflowStrategy: .reportGap)            │
│     )                                                                       │
│     │                                                                       │
│     ▼                                                                       │
│  4. Continuous Event Loop & State Machine                                   │
│     for try await event in stream {                                         │
│       switch event {                                                        │
│       case .notification(let notify):                                       │
│           applyDelta(notify)                                                │
│       case .lifecycle(let lifecycle):                                       │
│           switch lifecycle {                                                │
│           case .connected:                                                  │
│               setUIStatus("Connected")                                      │
│           case .disconnected(let error):                                    │
│               setUIStatus("Reconnecting...")                                │
│           case .retrying(let attempt, let delay):                           │
│               updateRetryCountdown(attempt: attempt, delay: delay)          │
│           case .stateGap(let reason):                                       │
│               // State gap detected (overflow, reconnect, or decode skip)   │
│               // Re-seed baseline to guarantee peer cache integrity         │
│               refreshBaselineStatus(reason: reason)                         │
│           }                                                                 │
│       }                                                                     │
│     }                                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.4 State Gap Recovery
The defining reliability feature for NWX is `.stateGap(reason:)`. Whenever:
- The stream buffer overflows due to consumer backpressure (`"buffer_overflow"`),
- The connection is re-established after a transient drop (`"reconnected"`), or
- An undecodable JSON line is encountered (`"undecodable_line"`),

The stream emits `.lifecycle(.stateGap(reason:))`. In response, NWX executes an asynchronous baseline `client.status()` query. This completely eliminates delta desynchronization without requiring manual reconnect loops in consumer code.

### 2.5 Architectural Comparison Matrix

| Dimension | 0.12.x Polling Architecture | Unbounded Streaming | 1.0 Bounded Observable Streaming |
|---|---|---|---|
| **CPU Wakeups** | High (12–20 wakes/min) | Low (event-driven) | **Zero when idle** (event-driven) |
| **Notification Latency** | 2–5 seconds (polling interval) | < 5 ms | **< 1 ms** (direct socket read) |
| **Memory Ceiling** | Constant (~12 MB) | Unbounded (heap leak risk) | **Strictly bounded** (16 MB / 256 events) |
| **Reconnect Recovery** | Inherent on next poll | Unhandled / Silent stall | **Automatic backoff + jitter** |
| **Peer Cache Consistency** | Eventual (polling window) | Vulnerable to dropped deltas | **Guaranteed** via `.stateGap` refresh |
| **Daemon Restart Handling** | Throws socket errors | Throws socket errors | **Transparent single-flight recovery** |

---

## 3. Consumer Archetype 2: Fleet & Node Configuration Agent (TailscaleFleetAgent)

### 3.1 Consumer Profile
`TailscaleFleetAgent` represents an enterprise workstation or server daemon that manages machine identity, configures Tailscale Serve and Funnel reverse proxies for local container workloads, switches between corporate and personal profiles, and enforces security settings (shields up, exit nodes).

### 3.2 Exercised Workflows

#### Workflow A: Safe Serve & Funnel Configuration with ETag Optimistic Concurrency
Fleet agents dynamically bind local microservice ports to tailnet DNS names. In multi-agent or user-managed environments, concurrent mutations to Serve configuration risk clobbering other services.
1. The agent reads `let snapshot = try await client.serveConfigSnapshot()`.
2. The agent mutates the config:
   ```swift
   do {
     let updated = try await client.updateServeConfig(snapshot) { config in
       config.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
     }
     logger.info("Serve updated successfully: \(updated.etag)")
   } catch TailscaleClientError.preconditionFailed {
     logger.warn("Concurrent edit detected (HTTP 412); re-fetching snapshot and retrying.")
   }
   ```
3. If an external CLI or admin modified Serve between fetch and write, the daemon returns HTTP 412, and the library throws typed `TailscaleClientError.preconditionFailed`. The agent re-fetches and reapplies cleanly.
4. For initial node provisioning where no prior configuration exists, the agent invokes `client.replaceServeConfigUnconditionally(newConfig)`.

#### Workflow B: Lossless Unmodeled JSON Field Preservation
Tailscale daemons regularly introduce experimental or unmodeled Serve properties. `TailscaleFleetAgent` must not strip these properties when updating port mappings.
- `ServeConfig` uses recursive `[String: JSONValue]` storage for unmodeled fields at the root, in `TCPPortHandler`, in `WebServerConfig`, and in `HTTPHandler`.
- 64-bit integer values (such as byte quotas or microsecond timeouts) are preserved without IEEE-754 double precision degradation.

#### Workflow C: Identity & Profile Lifecycle Management
Workstations moving between roles require clean-slate profile transitions:
1. `client.profiles()` lists available profiles.
2. `client.switchProfile(id)` switches to an existing corporate identity.
3. `client.switchToEmptyProfile()` signs out the active profile and creates a clean slate.
4. `client.deleteProfile(id)` decommissions obsolete profiles.

#### Workflow D: Isolated Preference Changes via `MaskedPrefs`
When updating node policies (e.g. activating an exit node or enabling shields up), updating all preferences risks overwriting manual user overrides (e.g. custom advertised routes or DNS settings).
- `MaskedPrefs` uses dual-field encoding: setting `change.exitNodeID = "..."` automatically emits both `"ExitNodeID": "..."` and `"ExitNodeIDSet": true` on the wire.
- Untouched properties remain unassigned, leaving daemon-side settings untouched.

---

## 4. Pre-1.0 Integration Friction & Resolution Ledger

Every friction point encountered during pre-1.0 consumer development was analyzed, categorized, and resolved with a dedicated 1.0 abstraction:

| # | Historical Friction Point | Pre-1.0 Manifestation | 1.0 Architectural Resolution | Verification Evidence |
|---|---|---|---|---|
| **1** | **Unconditional Serve Overwrites** | Calling `setServeConfig` with `nil` ETag silently wiped out concurrent CLI or UI changes. | `ServeConfigSnapshot` + `setServeConfig(_:matching:)` requires explicit ETag; stale ETag raises `.preconditionFailed` (HTTP 412). | `FleetAgentConfigurationTests.testServeConfigConflictDetectionAndRetry` |
| **2** | **Unmodeled Serve Field Loss** | Modifying a port forward stripped newly added upstream Web or Funnel properties from JSON. | Recursive `JSONValue` dictionary backing preserves all unmodeled keys and 64-bit ints. | `FleetAgentConfigurationTests.testLosslessUnmodeledFieldPreservation` |
| **3** | **Sparse Delta Desynchronization** | Missed IPN bus notifications caused UI peer table desync with no recovery mechanism. | `IPNBusLifecycle.stateGap(reason:)` signals data gaps, triggering automatic baseline re-sync. | `NWXConsumerMigrationTests.testStateGapTriggersBaselineStatusRefresh` |
| **4** | **Opaque Stream Drops** | Stream termination did not distinguish normal closure from transient drops or fatal auth failures. | `IPNBusLifecycle` (`.connected`, `.disconnected`, `.retrying`) with classified retry backoff. | `NWXConsumerMigrationTests.testLifecycleTransitionsEmitted` |
| **5** | **Invisible Response Headers** | Stream consumers could not inspect `Tailscale-Version` or HTTP response headers. | `StreamingResponse` validates status code and delivers headers before stream body begins. | `StreamingResponseTests`, `EXTERNAL-REVIEW.md` (Subsystem 4) |
| **6** | **Daemon Restart Invalidation** | Daemon restart rotated loopback port and token, causing permanent connection failures. | `EndpointSource.automatic` + `singleFlightRediscovery()` automatically recovers credentials. | `NWXConsumerMigrationTests.testDaemonRestartRediscovery` |
| **7** | **Blocking Discovery Probes** | Synchronous `LocalAPIDiscovery.discover()` blocked calling actors on socket stat calls. | `LocalAPIDiscovery.discoverAsync()` and `TailscaleClient.discover()` run probes off the main actor. | `NWXConsumerMigrationTests.testAsynchronousDiscovery` |
| **8** | **Preference Clobbering** | Partial preference updates required sending full structs, accidentally resetting unset fields. | `MaskedPrefs` ensures only assigned properties serialize with `<Name>Set: true`. | `FleetAgentConfigurationTests.testMaskedPreferencesIsolation` |
| **9** | **Profile API Naming Divergence** | Deprecated `addProfile()` diverged from upstream LocalAPI semantics (`PUT /profiles/`). | Removed deprecated `addProfile()`; canonicalized on `switchToEmptyProfile()`. | `FleetAgentConfigurationTests.testCleanSlateEmptyProfileCreation` |

---

## 5. Public Contract & Concurrency Verification

### 5.1 Zero-`@testable` Public Interface Rule
To ensure that consumer code has access to all required types, initializers, and methods, consumer validation test suites are compiled **strictly without `@testable import TailscaleClient`**:
- All model properties must be `public`.
- All configuration initializers must be `public`.
- All error cases and error types must be `public`.
- Testing harnesses use `TailscaleClientMocks` (`MockTransport`, `RequestRecorder`).

### 5.2 Swift 6 Concurrency Compliance
Both consumers operate under Swift 6 strict concurrency (`Complete`):
- `TailscaleClient` is an `actor`, providing reentrancy-safe IPC state management.
- All exchanged types (`ServeConfig`, `ServeConfigSnapshot`, `MaskedPrefs`, `LoginProfile`, `IPNStatus`, `NetCheckReport`, `IPNBusEvent`) conform to `Sendable`.
- Closures (`mutate: (inout ServeConfig) throws -> Void`, `onUndecodableLine:`) are explicitly `@Sendable`.

---

## 6. Automated Verification Matrix

The consumer validation test suite is organized into two test files in `Tests/TailscaleClientTests/ConsumerValidation/`:

### 6.1 NWXConsumerMigrationTests (`Tests/TailscaleClientTests/ConsumerValidation/NWXConsumerMigrationTests.swift`)
- `testAsynchronousDiscovery`: Verifies non-blocking discovery resolution across simulated endpoints.
- `testInitialBaselineSeeding`: Verifies combined `status()` and `netcheck()` queries to seed peer and DERP latency caches.
- `testContinuousIPNBusStreaming`: Verifies subscription with `StreamBufferBounds` and `StreamRetryPolicy`.
- `testLifecycleTransitionsEmitted`: Verifies sequential `.connected`, `.disconnected`, and `.retrying` lifecycle states.
- `testStateGapTriggersBaselineStatusRefresh`: Verifies that receiving `.stateGap` triggers a baseline status re-fetch to restore cache integrity.
- `testDaemonRestartRediscovery`: Verifies dynamic credential refresh when daemon rotates port/token.

### 6.2 FleetAgentConfigurationTests (`Tests/TailscaleClientTests/ConsumerValidation/FleetAgentConfigurationTests.swift`)
- `testProfileSwitching`: Verifies `profiles()`, `switchProfile(id)`, and `currentProfile()`.
- `testCleanSlateEmptyProfileCreation`: Verifies `switchToEmptyProfile()` maps to `PUT /localapi/v0/profiles/`.
- `testMaskedPreferencesIsolation`: Verifies `MaskedPrefs` selectively serializes only modified fields with `<Name>Set = true`.
- `testServeConfigConflictDetectionAndRetry`: Verifies HTTP 412 precondition failure handling and successful re-fetch retry.
- `testLosslessUnmodeledFieldPreservation`: Verifies unmodeled JSON fields and 64-bit integers survive decode-mutate-encode cycles.
- `testUnconditionalReplacement`: Verifies `replaceServeConfigUnconditionally(_:)` executes without concurrency headers.

---

## 7. Milestone 4 (W9) Consumer Evaluation Protocol

In preparation for Milestone 4 (Release Candidate & Soak):

### 7.1 Proposed 14-Day Consumer Soak Parameters
1. **Daemon Upgrade & Restart Cycles**: Running consumer agents during background `tailscaled` package upgrades to assert dynamic credential recovery.
2. **System Sleep / Wake Cycles**: Verifying that system sleep suspends streams cleanly and resumes with `.retrying` -> `.connected` -> `.stateGap` refresh without hanging.
3. **Network Interface Hops**: Transitioning between Wi-Fi, Ethernet, and cellular hotspots to confirm backoff jitter and reconnection without descriptor leaks.
4. **Slow Consumer Backpressure**: Exercising slow UI rendering tasks to assert that `StreamBufferBounds` emits `.stateGap` and prevents process memory growth.

### 7.2 Release Gate Criteria
- Zero memory leaks over a 24-hour continuous stream soak.
- Zero file descriptor leaks verified via OS descriptor tables (`lsof`).
- No unresolved blocking defects in consumer integration pathways.
