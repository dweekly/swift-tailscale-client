# Project: swift-tailscale-client 1.0 Implementation

## Architecture
`swift-tailscale-client` is a Swift 6 package providing a production-grade, typed client for the Tailscale LocalAPI daemon. It communicates over POSIX Unix domain sockets or HTTP loopback with zero external third-party package dependencies.

### Module & Package Boundaries
- **`Sources/TailscaleClient`**: The primary library product.
  - `Configuration/`: `LocalAPIDiscovery`, `TailscaleClientConfiguration`, `EndpointSource`.
  - `Models/`: Strongly typed, Sendable wire models (`ServeConfig`, `ServeConfigSnapshot`, `JSONValue`, `IPNNotify`, `IPNBusEvent`, `StatusResponse`, `WhoIsResponse`, `PrefsResponse`, `MaskedPrefs`, `Certificates`, etc.).
  - `Transport/`: Low-level wire protocol framing (`TailscaleTransport`, `UnixSocketTransport`, `URLSessionTailscaleTransport`, `HTTPWireFormat`, `ChunkedTransferDecoder`, `StreamingResponse`).
  - `Platform/`: OS-specific discovery helpers (`MacClientInfo`, `NetworkInterfaceDiscovery`).
  - `Support/`: `DecodingSupport`, `DiscoveryLog`.
  - Client Facades: `TailscaleClient` (main actor), `ServeAPI`, `DaemonControlAPI`, `StableParityAPI`, `Experimental`.
- **`Sources/TailscaleClientMocks`**: Test mocking product providing scriptable `MockTransport` and `RequestRecorder`.
- **`Sources/tailscale-swift`**: Command-line tool using `swift-argument-parser`.
- **`Tests/TailscaleClientTests`**: Comprehensive unit, fault, and conformance test suites (`ReadinessRegressionTests`, `UnixSocketFaultTests`, `FaultUnixServer`, `ServeConfigLosslessTests`, `IPNBusStreamingTests`, `ConformanceTests`, `E2E/`).
- **`Scripts/`**: Verification tooling, maturity tracking, fixture capture, evidence aggregation, and release consistency gates.

### Code Layout
- Exclusive ownership per milestone:
  - M1 (W1: PR 02, PR 03): `Sources/TailscaleClient/Models/ServeConfig.swift`, `Sources/TailscaleClient/Models/JSONValue.swift`, `Sources/TailscaleClient/Models/ServeConfigSnapshot.swift`, `Sources/TailscaleClient/Support/DecodingSupport.swift`, `Sources/TailscaleClient/ServeAPI.swift`, `Sources/TailscaleClient/TailscaleClientError.swift`, `Tests/TailscaleClientTests/ReadinessRegressionTests.swift`, `Tests/TailscaleClientTests/ServeConfigLosslessTests.swift`, `Tests/TailscaleClientTests/ServeAPITests.swift`, `Examples/Recipes/Sources/Recipes/ServeAndCertificates.swift`.
  - M1 (W2: PR 04, PR 05): `Sources/TailscaleClient/Transport/HTTPWireFormat.swift`, `Sources/TailscaleClient/Transport/ChunkedTransferDecoder.swift`, `Sources/TailscaleClient/Transport/UnixSocketTransport.swift`, `Tests/TailscaleClientTests/ReadinessRegressionTests.swift`, `Tests/TailscaleClientTests/UnixSocketFaultTests.swift`, `Tests/TailscaleClientTests/FaultUnixServer.swift`.
  - M1 (W3: PR 06, PR 07): `Sources/TailscaleClient/Transport/TailscaleTransport.swift`, `Sources/TailscaleClient/Transport/URLSessionTailscaleTransport.swift`, `Sources/TailscaleClientMocks/MockTransport.swift`, `Sources/TailscaleClient/Models/IPNNotify.swift`, `Sources/TailscaleClient/TailscaleClient.swift`, `Tests/TailscaleClientTests/StreamingTransportTests.swift`, `Tests/TailscaleClientTests/IPNBusStreamingTests.swift`.
  - M2 (W4: PR 08, PR 09): `Sources/TailscaleClient/Configuration/LocalAPIDiscovery.swift`, `Sources/TailscaleClient/Platform/MacClientInfo.swift`, `Sources/TailscaleClient/Configuration/TailscaleClientConfiguration.swift`, `Sources/TailscaleClient/TailscaleClient.swift`, `Tests/TailscaleClientTests/LocalAPIDiscoveryTests.swift`, `Tests/TailscaleClientTests/DiscoveryRecoveryTests.swift`.
  - M2 (W5: PR 10, PR 11): `Scripts/capture-fixtures.py`, `Documentation/endpoints.json`, `Tests/TailscaleClientTests/Fixtures/`, `Scripts/conformance-harness.go`, `Tests/TailscaleClientTests/ConformanceTests.swift`, `Documentation/CONFORMANCE.md`, `Package.swift`.
  - M2 (W6: PR 12): `.github/workflows/ci.yml`, `.github/workflows/integration-linux.yml`, `.github/workflows/release.yml`, `Scripts/aggregate-release-evidence.py`.
  - M3 (W7: PR 13, PR 14): `Sources/TailscaleClient/ProfilesAPI.swift`, `Sources/TailscaleClient/TailscaleClient.swift`, `Package.swift`, `Tests/TailscaleClientTests/APICompatibilityTests.swift`, `Documentation/INTEGRATING.md`, `Sources/TailscaleClient/TailscaleClient.docc/`.
  - M3 (W8: PR 14): `CHANGELOG.md`, `SECURITY.md`, `CONTRIBUTING.md`, `.claude/skills/swift-tailscale-client/SKILL.md`, `Examples/`.
  - M4 (W9: PR 15): `Documentation/releases/1.0.0.json`, `CHANGELOG.md`, Release candidate evidence and tags.

---

## Feature Inventory
Every feature from the survey is inventoried below with its assigned milestone and source specification.

| # | Feature ID | Feature Description | Milestone | PR # | Source Spec | Status |
|---|---|---|---|---|---|---|
| 1 | FEAT-01 | Recursive lossless unknown field preservation in `ServeConfig` (root & nested) | M1 | PR 02 | PLAN W1, DEC-1 | DONE (`5e6ddc7`) |
| 2 | FEAT-02 | 64-bit integer precision preservation in `JSONValue` | M1 | PR 02 | PLAN W1, DEC-1 | DONE (`5e6ddc7`) |
| 3 | FEAT-03 | `ServeConfigSnapshot` concurrency encapsulation | M1 | PR 03 | PLAN W1, DEC-1 | DONE (`bbbe54a`) |
| 4 | FEAT-04 | Safe conditional `setServeConfig(_:matching:)` and `updateServeConfig` API | M1 | PR 03 | PLAN W1, DEC-1 | DONE (`bbbe54a`) |
| 5 | FEAT-05 | Explicit unconditional replacement `replaceServeConfigUnconditionally` API | M1 | PR 03 | PLAN W1, DEC-1 | DONE (`bbbe54a`) |
| 6 | FEAT-06 | Unconditional 64 KiB HTTP head limit in `HTTPHeadBuffer` | M1 | PR 04 | PLAN W2, DEC-2 | DONE (`3be767b`) |
| 7 | FEAT-07 | Content-Length body framing validation in unary responses | M1 | PR 04 | PLAN W2, DEC-2 | DONE (`3be767b`) |
| 8 | FEAT-08 | ChunkedTransferDecoder completion check (`isComplete`) | M1 | PR 04 | PLAN W2, DEC-2 | DONE (`3be767b`) |
| 9 | FEAT-09 | Configurable response and line size bounds | M1 | PR 04 | PLAN W2, DEC-2 | DONE (`3be767b`) |
| 10 | FEAT-10 | Cooperative non-blocking socket cancellation | M1 | PR 05 | PLAN W2, DEC-2 | DONE (`f7ead04`) |
| 11 | FEAT-11 | Single-ownership socket descriptor cleanup (zero leaks over 100+ cycles) | M1 | PR 05 | PLAN W2, DEC-2 | DONE (`f7ead04`) |
| 12 | FEAT-12 | `StreamingResponse` delivering head metadata before body stream | M1 | PR 06 | PLAN W3, DEC-2 | DONE (`be6bb42`) |
| 13 | FEAT-13 | Daemon version and capability validation in stream setup | M1 | PR 06 | PLAN W3, DEC-2 | DONE (`be6bb42`) |
| 14 | FEAT-14 | Scriptable streaming mock in `MockTransport` | M1 | PR 06 | PLAN W3, DEC-2 | DONE (`be6bb42`) |
| 15 | FEAT-15 | `IPNBusEvent` with `.notification` and `.lifecycle` cases | M1 | PR 07 | PLAN W3, DEC-3 | DONE (`7f9208f`, `664d953`) |
| 16 | FEAT-16 | Bounded streaming queue with explicit gap/overflow reporting | M1 | PR 07 | PLAN W3, DEC-3 | DONE (`7f9208f`, `664d953`) |
| 17 | FEAT-17 | Classified retry with capped exponential backoff and jitter | M1 | PR 07 | PLAN W3, DEC-3 | DONE (`7f9208f`, `664d953`) |
| 18 | FEAT-18 | Native macOS standalone `.pkg` app discovery (`ipnport` symlink & token) | M2 | PR 08 | PLAN W4, DEC-4 | DONE (`c8c50ec`, `0dfc37f`) |
| 19 | FEAT-19 | Asynchronous discovery API `discoverAsync()` | M2 | PR 08 | PLAN W4 | DONE (`c8c50ec`, `0dfc37f`) |
| 20 | FEAT-20 | Multi-platform descriptor passing & client-side token refresh | M2 | PR 09 | PLAN W4 | DONE (`182d239`, `0dfc37f`) |
| 21 | FEAT-21 | Transport factory decoupling and dependency injection | M2 | PR 09 | PLAN W4 | DONE (`182d239`, `0dfc37f`) |
| 22 | FEAT-22 | Platform matrix documentation update (`SUPPORT.md`) | M2 | PR 09 | PLAN W4, SUPP | DONE (`182d239`) |
| 23 | FEAT-23 | Fixture capture and sanitization tooling (`Scripts/capture-fixtures.py`) | M2 | PR 10 | PLAN W5 | DONE (`d7bc318`, `1f8c798`) |
| 24 | FEAT-24 | Versioned fixture matrix across supported daemon versions (1.76.x - 1.96.x) | M2 | PR 10 | PLAN W5, SUPP | DONE (`d7bc318`, `1f8c798`) |
| 25 | FEAT-25 | Go-vs-Swift LocalAPI differential conformance test harness | M2 | PR 11 | PLAN W5 | DONE (`2f97938`, `1f8c798`) |
| 26 | FEAT-26 | Disposable production tailnet evidence for control-plane features | M2 | PR 11 | PLAN W5 | DONE (`2f97938`, `1f8c798`) |
| 27 | FEAT-27 | Exact-version Linux/Headscale CI matrix workflow | M2 | PR 12 | PLAN W6 | DONE (`61cccda`, `7d4b8bd`) |
| 28 | FEAT-28 | Exact-SHA release evidence aggregation tooling | M2 | PR 12 | PLAN W6 | DONE (`61cccda`, `7d4b8bd`) |
| 29 | FEAT-29 | Staged release rehearsal and negative gate validation | M2 | PR 12 | PLAN W6 | DONE (`61cccda`, `7d4b8bd`) |
| 30 | FEAT-30 | Public API audit and deprecated symbol removal (`addProfile`) | M3 | PR 13 | PLAN W7 | DONE (`c4438b4`) |
| 31 | FEAT-31 | Compiler-enforced source compatibility baseline checking | M3 | PR 13 | PLAN W7, DEC-5 | DONE (`c4438b4`) |
| 32 | FEAT-32 | Comprehensive authored DocC documentation (100% coverage) | M3 | PR 14 | PLAN W7 | DONE (`2b67179`) |
| 33 | FEAT-33 | Consumer integration migration (NWX & secondary consumer) | M3 | PR 14 | PLAN W8 | DONE (`908d3b2`) |
| 34 | FEAT-34 | Maintenance, security, and governance rehearsal | M3 | PR 14 | PLAN W8, SUPP | DONE (`908d3b2`) |
| 35 | FEAT-35 | 14-day consumer evaluation and 24-hour soak verification | M4 | PR 15 | PLAN W9 | DONE |
| 36 | FEAT-36 | Final 1.0 release packaging, checksums, and publication | M4 | PR 15 | PLAN W9 | DONE |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|---|---|---|---|
| M1 | Core Correctness & Reliability | PR 02 – PR 07 (W1, W2, W3): Lossless ServeConfig, snapshot concurrency, 64 KiB head limit, strict framing, zero FD leaks, StreamingResponse head metadata, bounded IPN streaming, classified reconnect backoff | M0 (Done) | DONE (`5e6ddc7`, `bbbe54a`, `3be767b`, `f7ead04`, `be6bb42`, `7f9208f`, `664d953`) |
| M2 | Discovery & Compatibility | PR 08 – PR 12 (W4, W5, W6): Native macOS/Linux discovery, async discovery, credential recovery, versioned fixtures, Go conformance harness, CI matrix, exact-SHA release aggregator | M1 | DONE (`c8c50ec`, `182d239`, `0dfc37f`, `d7bc318`, `2f97938`, `1f8c798`, `61cccda`, `7d4b8bd`) |
| M3 | Hardening & Pre-Release | PR 13 – PR 14 (W7, W8): Public API freeze, deprecation removal (`addProfile`), 100% authored DocC coverage, consumer validation (NWX), maintenance & security governance | M2 | DONE (`c4438b4`, `2b67179`, `908d3b2`) |
| M4 | 1.0 Release Freeze & Delivery | PR 15 (W9): 100% E2E test suite pass, soak testing, defect closure, final 1.0.0 release packaging, checksums, publication rehearsal | M3, E2E-READY | DONE |
| E2E | E2E Testing Track | Test infra and requirement-driven test cases (Tiers 1–4) covering all 36 features independently; publishes TEST_READY.md | none (runs in parallel with M1-M3) | DONE (`6ed31a5`, TEST_READY.md published) |

---

## Interface Contracts

### 1. ServeConfig & Concurrency (`Models/ServeConfig.swift` ↔ `ServeAPI.swift`) [IMPLEMENTED & VERIFIED]
```swift
public struct ServeConfigSnapshot: Sendable, Equatable {
  public let etag: String
  public let fetchedAt: Date
  public let config: ServeConfig
}

extension TailscaleClient {
  public func serveConfigSnapshot() async throws -> ServeConfigSnapshot
  public func setServeConfig(
    _ newConfig: ServeConfig,
    matching snapshot: ServeConfigSnapshot
  ) async throws -> ServeConfigSnapshot
  public func updateServeConfig(
    _ snapshot: ServeConfigSnapshot,
    mutate: (inout ServeConfig) throws -> Void
  ) async throws -> ServeConfigSnapshot
  public func replaceServeConfigUnconditionally(_ config: ServeConfig) async throws
}
```
- Missing/empty ETag throws `TailscaleClientError.missingConcurrencyToken`.
- HTTP 412 throws `TailscaleClientError.preconditionFailed(body:endpoint:)`.
- `ServeConfig` retains unmodeled keys losslessly with exact 64-bit integer representation.

### 2. Transport & Framing (`Transport/TailscaleTransport.swift` ↔ `Transport/UnixSocketTransport.swift`)
```swift
public struct StreamingResponse: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: AsyncThrowingStream<Data, Error>
}

public protocol TailscaleTransport: Sendable {
  func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
    async throws -> TailscaleResponse
  func sendStreaming(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
    async throws -> StreamingResponse
}
```
- `HTTPHeadBuffer.feed`: Enforces `head.count <= 64 * 1024` even when delimiter is present.
- Unary: Rejects truncated `Content-Length` and incomplete chunked streams.
- Sockets: Non-blocking cooperative polling (`waitReadable`, timeout ≤ 500 ms) checking `Task.isCancelled`. Single-ownership socket close (0 leaks).

### 3. IPN Bus Monitoring (`Models/IPNNotify.swift` ↔ `TailscaleClient.swift`)
```swift
public enum IPNBusEvent: Sendable {
  case notification(IPNNotify)
  case lifecycle(IPNBusLifecycle)
}

public enum IPNBusLifecycle: Sendable, Equatable {
  case connected
  case disconnected(underlying: String)
  case retrying(attempt: Int, delay: Duration)
  case stateGap(reason: String)
}

extension TailscaleClient {
  public func watchIPNBusEvents(
    options: NotifyWatchOpt = .default,
    retryPolicy: StreamRetryPolicy = .default
  ) async throws -> AsyncThrowingStream<IPNBusEvent, Error>
}
```
- Stream queues bounded to 256 events or 16 MB.
- Queue overflow emits `.lifecycle(.stateGap(reason: "buffer_overflow"))` or throws `TailscaleClientError.streamOverflow`.
- Capped exponential backoff with jitter. Permanent 401/403 terminate immediately.

### 4. Discovery & Credential Refresh (`Configuration/LocalAPIDiscovery.swift` ↔ `Configuration/TailscaleClientConfiguration.swift` ↔ `TailscaleClient.swift`)
```swift
public enum EndpointSource: Sendable, Equatable {
  case automatic(LocalAPIDiscovery)
  case pinned(TailscaleEndpoint)
}

extension LocalAPIDiscovery {
  public func discoverAsync() async throws -> Result
}
```
- Standalone `.pkg` app discovery reads `/Library/Tailscale/ipnport` symlink & `/Library/Tailscale/ipnport.token` without TCC.
- App Store GUI requires opt-in `allowMacOSAppStoreDiscovery: true`.
- `.automatic` clients perform single-flight credential refresh and socket re-probe on daemon restart (ECONNREFUSED/401/403); `.pinned` clients never auto-rediscover.
