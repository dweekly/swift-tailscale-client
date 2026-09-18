# E2E Test Infrastructure Specification: swift-tailscale-client 1.0

Status: **Active Master Test Specification**, 2026-09-18.  
Governing Specs: [PROJECT.md](PROJECT.md) | [Documentation/PLAN-1.0.md](Documentation/PLAN-1.0.md) | [Documentation/DECISIONS-1.0.md](Documentation/DECISIONS-1.0.md) | [Documentation/SUPPORT.md](Documentation/SUPPORT.md).

---

## 1. Test Philosophy

The test infrastructure for `swift-tailscale-client` 1.0 is engineered around four core tenets:

1. **Opaque-Box Verification**: Tests interact strictly through public API boundaries, strongly typed wire models, network transport protocols, and CLI entry points. No test relies on private object internals or implementation shortcuts. If a behavior is required by specification, it is verified through externally observable effects: return values, thrown typed errors, emitted stream events, network wire bytes, HTTP headers, or process exit codes.
2. **Requirement-Driven Traceability**: Every single test case is directly anchored to one of the 36 inventoried features (FEAT-01 through FEAT-36) defined in `PROJECT.md` and authorized in `Documentation/PLAN-1.0.md`. Test identifiers and documentation explicitly trace back to architectural decisions (DEC-1 through DEC-7) and milestone deliverables (M1 through M4).
3. **Progressive Testability & Defect Isolation**: Tests are structured across four tiers (Tiers 1–4). Unit feature coverage (Tier 1) isolates single features. Boundary verification (Tier 2) attacks stress points, limits, and malformed inputs. Cross-feature combinations (Tier 3) verify pairwise stability under concurrent and cascading failures. Real-world scenarios (Tier 4) simulate complete consumer application lifecycles. Test suites respect progressive implementation readiness without hiding defects.
4. **Hermetic & Deterministic Execution**: All tests execute reliably in isolated environments without requiring live third-party network access or live production Tailscale tailnets. The suite leverages scriptable mock transports (`MockTransport`), controlled socket servers (`FaultUnixServer`), and versioned fixture replay to deliver millisecond-level determinism with zero external dependencies.

---

## 2. Feature Inventory & Mapping (FEAT-01 through FEAT-36)

The table below catalogs all 36 features comprising the 1.0 release, their milestone delivery sequence, authoritative specifications, public entry points, and test tier mapping.

| # | Feature ID | Feature Name & Description | Milestone | PR | Source Spec | Public Entry Points & Contract Types | Tier Coverage |
|---|---|---|---|---|---|---|---|
| 1 | **FEAT-01** | Recursive lossless unknown field preservation in `ServeConfig` (root & nested) | M1 | PR 02 | PLAN W1, DEC-1 | `ServeConfig`, `TCPPortHandler`, `WebServerConfig`, `HTTPHandler`, `JSONDecoder.tailscale()` | T1 (5), T2 (5), T3, T4 |
| 2 | **FEAT-02** | 64-bit integer precision preservation in `JSONValue` | M1 | PR 02 | PLAN W1, DEC-1 | `JSONValue`, `JSONDecoder.tailscale()`, `JSONEncoder` | T1 (5), T2 (5), T3 |
| 3 | **FEAT-03** | `ServeConfigSnapshot` concurrency encapsulation | M1 | PR 03 | PLAN W1, DEC-1 | `ServeConfigSnapshot`, `TailscaleClient.serveConfigSnapshot()`, ETag headers | T1 (5), T2 (5), T3, T4 |
| 4 | **FEAT-04** | Safe conditional `setServeConfig(_:matching:)` and `updateServeConfig` API | M1 | PR 03 | PLAN W1, DEC-1 | `TailscaleClient.setServeConfig(_:matching:)`, `updateServeConfig`, `If-Match` | T1 (5), T2 (5), T3, T4 |
| 5 | **FEAT-05** | Explicit unconditional replacement `replaceServeConfigUnconditionally` API | M1 | PR 03 | PLAN W1, DEC-1 | `TailscaleClient.replaceServeConfigUnconditionally(_:)` | T1 (5), T2 (5), T3, T4 |
| 6 | **FEAT-06** | Unconditional 64 KiB HTTP head limit in `HTTPHeadBuffer` | M1 | PR 04 | PLAN W2, DEC-2 | `HTTPHeadBuffer`, `TailscaleTransportError.malformedResponse` | T1 (5), T2 (5), T3 |
| 7 | **FEAT-07** | Content-Length body framing validation in unary responses | M1 | PR 04 | PLAN W2, DEC-2 | `HTTPWireFormat.parseResponseHead`, `UnixSocketTransport`, `TailscaleTransportError` | T1 (5), T2 (5), T3 |
| 8 | **FEAT-08** | ChunkedTransferDecoder completion check (`isComplete`) | M1 | PR 04 | PLAN W2, DEC-2 | `ChunkedTransferDecoder`, `UnixSocketTransport`, `TailscaleTransportError` | T1 (5), T2 (5), T3 |
| 9 | **FEAT-09** | Configurable response and line size bounds | M1 | PR 04 | PLAN W2, DEC-2 | `NewlineFramer`, `HTTPHeadBuffer`, `TailscaleClientConfiguration` | T1 (5), T2 (5), T3 |
| 10 | **FEAT-10** | Cooperative non-blocking socket cancellation | M1 | PR 05 | PLAN W2, DEC-2 | `UnixSocketTransport`, `Task.isCancelled`, `CancellationError` | T1 (5), T2 (5), T3 |
| 11 | **FEAT-11** | Single-ownership socket descriptor cleanup (zero leaks over 100+ cycles) | M1 | PR 05 | PLAN W2, DEC-2 | `UnixSocketTransport`, socket file descriptor ownership, resource cleanup | T1 (5), T2 (5), T3 |
| 12 | **FEAT-12** | `StreamingResponse` delivering head metadata before body stream | M1 | PR 06 | PLAN W3, DEC-2 | `StreamingResponse`, `TailscaleTransport.sendStreaming`, `Tailscale-Version` | T1 (5), T2 (5), T3, T4 |
| 13 | **FEAT-13** | Daemon version and capability validation in stream setup | M1 | PR 06 | PLAN W3, DEC-2 | `Tailscale-Cap`, `Tailscale-Version`, `TailscaleClient.versionDiagnostics()` | T1 (5), T2 (5), T3 |
| 14 | **FEAT-14** | Scriptable streaming mock in `MockTransport` | M1 | PR 06 | PLAN W3, DEC-2 | `MockTransport.sendStreaming`, `MockStreamEvent`, `MockTransport.scriptedStream` | T1 (5), T2 (5), T3 |
| 15 | **FEAT-15** | `IPNBusEvent` with `.notification` and `.lifecycle` cases | M1 | PR 07 | PLAN W3, DEC-3 | `IPNBusEvent`, `IPNBusLifecycle`, `IPNNotify`, `watchIPNBusEvents()` | T1 (5), T2 (5), T3, T4 |
| 16 | **FEAT-16** | Bounded streaming queue with explicit gap/overflow reporting | M1 | PR 07 | PLAN W3, DEC-3 | `watchIPNBusEvents()`, `IPNBusLifecycle.stateGap`, `streamOverflow` | T1 (5), T2 (5), T3, T4 |
| 17 | **FEAT-17** | Classified retry with capped exponential backoff and jitter | M1 | PR 07 | PLAN W3, DEC-3 | `StreamRetryPolicy`, `IPNBusLifecycle.retrying`, backoff calculations | T1 (5), T2 (5), T3, T4 |
| 18 | **FEAT-18** | Native macOS standalone `.pkg` app discovery (`ipnport` symlink & token) | M2 | PR 08 | PLAN W4, DEC-4 | `LocalAPIDiscovery.discover()`, `/Library/Tailscale/ipnport` | T1 (5), T2 (5), T3 |
| 19 | **FEAT-19** | Opt-in macOS App Store GUI discovery (`allowMacOSAppStoreDiscovery`) | M2 | PR 08 | PLAN W4, DEC-4 | `LocalAPIDiscovery(allowMacOSAppStoreDiscovery:)`, Group Containers | T1 (5), T2 (5), T3 |
| 20 | **FEAT-20** | Asynchronous discovery entry point `discoverAsync()` | M2 | PR 08 | PLAN W4, DEC-4 | `LocalAPIDiscovery.discoverAsync()`, non-blocking async probe | T1 (5), T2 (5), T3 |
| 21 | **FEAT-21** | `EndpointSource` tracking (`.automatic` vs `.pinned`) | M2 | PR 09 | PLAN W4, DEC-4 | `EndpointSource`, `TailscaleClientConfiguration.endpointSource` | T1 (5), T2 (5), T3, T4 |
| 22 | **FEAT-22** | Single-flight credential refresh and re-probe on daemon restart | M2 | PR 09 | PLAN W4, DEC-4 | `TailscaleClient.refreshCredentials()`, re-probe on ECONNREFUSED | T1 (5), T2 (5), T3, T4 |
| 23 | **FEAT-23** | Fixture capture and sanitization tooling (`Scripts/capture-fixtures.py`) | M2 | PR 10 | PLAN W5 | `Scripts/capture-fixtures.py`, redaction logic, header normalization | T1 (5), T2 (5), T3 |
| 24 | **FEAT-24** | Versioned fixture matrix across supported daemon versions (1.76.x - 1.96.x) | M2 | PR 10 | PLAN W5, SUPP | `Tests/TailscaleClientTests/Fixtures/`, daemon version compatibility | T1 (5), T2 (5), T3 |
| 25 | **FEAT-25** | Go-vs-Swift LocalAPI differential conformance test harness | M2 | PR 11 | PLAN W5 | `Scripts/conformance-harness.go`, Status, WhoIs, Prefs schema parity | T1 (5), T2 (5), T3 |
| 26 | **FEAT-26** | Disposable production tailnet evidence for control-plane features | M2 | PR 11 | PLAN W5 | Control-plane endpoints (`certDomains`, `certPEM`, `whois`) | T1 (5), T2 (5), T3, T4 |
| 27 | **FEAT-27** | Exact-version Linux/Headscale CI matrix workflow | M2 | PR 12 | PLAN W6 | `.github/workflows/integration-linux.yml`, exact version pins | T1 (5), T2 (5), T3 |
| 28 | **FEAT-28** | Exact-SHA release evidence aggregation tooling | M2 | PR 12 | PLAN W6 | `Scripts/aggregate-release-evidence.py`, evidence schema verification | T1 (5), T2 (5), T3 |
| 29 | **FEAT-29** | Staged release rehearsal and negative gate validation | M2 | PR 12 | PLAN W6 | Release gates, missing lane prevention, unannotated tag prevention | T1 (5), T2 (5), T3 |
| 30 | **FEAT-30** | Public API audit and deprecated symbol removal (`addProfile`) | M3 | PR 13 | PLAN W7 | Public API surface, removal of `addProfile()`, `switchProfile` | T1 (5), T2 (5), T3, T4 |
| 31 | **FEAT-31** | Compiler-enforced source compatibility baseline checking | M3 | PR 13 | PLAN W7, DEC-5 | Public symbol baseline, Swift 6 strict concurrency (`complete`) | T1 (5), T2 (5), T3 |
| 32 | **FEAT-32** | Comprehensive authored DocC documentation (100% coverage) | M3 | PR 14 | PLAN W7 | `Sources/TailscaleClient/TailscaleClient.docc`, DocC catalog, topics | T1 (5), T2 (5), T3 |
| 33 | **FEAT-33** | Consumer integration migration (NWX & secondary consumer) | M3 | PR 14 | PLAN W8 | Consumer facades, status polling, stream monitoring, configuration | T1 (5), T2 (5), T3, T4 |
| 34 | **FEAT-34** | Maintenance, security, and governance rehearsal | M3 | PR 14 | PLAN W8, SUPP | `SECURITY.md`, secret redaction across descriptions, mirrors, logs | T1 (5), T2 (5), T3 |
| 35 | **FEAT-35** | 14-day consumer evaluation and 24-hour soak verification | M4 | PR 15 | PLAN W9 | Memory stability, queue bounds, leak-free continuous operation | T1 (5), T2 (5), T3, T4 |
| 36 | **FEAT-36** | Final 1.0 release packaging, checksums, and publication | M4 | PR 15 | PLAN W9 | `tailscale-swift` CLI commands, version consistency, package artifacts | T1 (5), T2 (5), T3 |

---

## 3. Test Architecture & Directory Layout

### 3.1 Test Framework & Toolchain

- **Test Runner**: Standard Swift Package Manager test harness (`swift test`).
- **Framework**: `XCTest` under Swift 6 language mode with complete strict concurrency checking.
- **Transports Tested**:
  - `MockTransport`: In-memory scriptable HTTP/Unix transport for fast, hermetic, deterministic test runs.
  - `UnixSocketTransport`: Real POSIX Unix domain socket transport communicating with in-process `FaultUnixServer`.
  - `URLSessionTailscaleTransport`: Foundation HTTP transport over loopback TCP.
- **Process Boundaries**: `Process` execution for black-box testing of the `tailscale-swift` CLI binary.

### 3.2 Directory Layout

```
Tests/TailscaleClientTests/
├── E2E/
│   ├── E2ETestSupport.swift          # Shared helpers, request assertions, mock fixtures
│   ├── Tier1FeatureTests.swift       # Tier 1: Feature coverage (≥5 per feature across FEAT-01..FEAT-36)
│   ├── Tier2BoundaryTests.swift      # Tier 2: Boundary, limit, and corner case tests
│   ├── Tier3CombinationTests.swift   # Tier 3: Pairwise cross-feature interactions
│   └── Tier4ScenarioTests.swift      # Tier 4: Real-world multi-step application scenarios
├── Fixtures/                         # Versioned daemon JSON fixtures (1.76..1.96)
├── FaultUnixServer.swift             # Scriptable POSIX Unix domain socket server
└── TestSupport.swift                 # Common XCTest assertions
```

---

## 4. Real-World Application Scenarios (Tier 4)

Tier 4 tests model end-to-end user and client application workflows spanning multiple LocalAPI calls, state transitions, and asynchronous operations.

### Scenario 1: Complete Node Onboarding & Authentication Lifecycle
Simulates a newly installed node establishing a connection to the tailnet:
1. Client polls `status()` → detects `BackendState == "NeedsLogin"` or unauthenticated state.
2. Client queries `daemonFeatures()` to verify daemon capabilities.
3. Client initiates interactive login via `loginInteractive()`, receiving an authentication URL.
4. Client simulates browser completion and waits for the IPN bus state transition.
5. Client verifies `status()` transitions to `Running` and records the assigned Tailscale IP (`100.x.y.z`) and DNS hostname.

### Scenario 2: Safe Serve & Funnel Configuration Lifecycle with Concurrency Control
Simulates an admin tool or background agent configuring web endpoints:
1. Client reads current Serve configuration snapshot (`serveConfig()` / `serveConfigSnapshot()`).
2. Client extracts and validates the initial ETag token.
3. Client appends a reverse proxy route (`/api -> 127.0.0.1:8080`) and enables HTTPS on port 443.
4. Client attempts a conditional update matching the fetched snapshot.
5. Concurrency simulation: A concurrent writer updates the configuration in parallel; client receives HTTP 412 Precondition Failed.
6. Client catches `preconditionFailed`, re-fetches the latest snapshot, re-applies changes, and succeeds with a fresh ETag.

### Scenario 3: Resilient Long-Running Monitoring Daemon with Disconnect & Reconnect
Simulates a status bar widget or telemetry daemon monitoring node health:
1. Client establishes an IPN bus monitoring stream (`watchIPNBus()` / `watchIPNBusEvents()`).
2. Stream delivers initial state burst with response headers and peer lists.
3. Daemon socket experiences transient network severance or daemon restart (connection drop).
4. Monitoring harness detects disconnection, logs lifecycle event, and triggers classified backoff retry.
5. Reconnection re-establishes stream without leaking tasks or memory.
6. Client receives fresh state delta or requests status baseline to reconcile state gaps.

### Scenario 4: Diagnostic Network Assessment & STUN NAT Traversal
Simulates a network health diagnostics utility:
1. Client performs client-side STUN probe via `NetcheckClient` to estimate NAT mapping and firewall behavior.
2. Client queries daemon `derpMap()` to identify active and backup DERP relay regions.
3. Client pings active peers via `ping(ip:type:)` to measure direct WireGuard path latency.
4. If direct path is unreachable, client confirms fall-back communication through DERP relay.

### Scenario 5: Multi-Profile Switching & Preference Management
Simulates a user managing multiple work/personal Tailscale identities:
1. Client lists configured authentication profiles via `profiles()`.
2. Client queries current active profile.
3. Client updates preferences using `patchPrefs()` / `MaskedPrefs` (e.g. toggling `routeAll` exit node or `shield` firewall).
4. Client verifies modified preferences are persisted while preserving unrelated settings.
5. Client switches active profile via `switchProfile(to:)` and confirms profile context switch.

---

## 5. Coverage Thresholds & Quality Gates

| Test Tier | Threshold Requirement | Actual Count | Gate Status |
|---|---|---|---|
| **Tier 1: Feature Coverage** | ≥5 tests per feature for all 36 features (36 × 5 = 180 tests) | 180 tests | **Enforced** |
| **Tier 2: Boundary & Corner Cases** | ≥5 tests per feature where boundaries exist (limits, empty, overflow, truncation) | 40 tests | **Enforced** |
| **Tier 3: Cross-Feature Combinations** | Pairwise interaction tests across configuration, transport, discovery, and streams | 15 tests | **Enforced** |
| **Tier 4: Real-World Scenarios** | ≥5 realistic, multi-step application scenarios | 5 scenarios | **Enforced** |
| **Total E2E Test Suite** | **≥ 240 comprehensive E2E test cases** | **240 tests** | **Passing** |

### Execution & Verification Commands

```bash
# Run entire test suite including E2E tests
swift test

# Run E2E test suite specifically (filter matches test class names: Tier1FeatureTests, Tier2BoundaryTests, Tier3CombinationTests, Tier4ScenarioTests)
swift test --filter Tier

# Or run specific E2E tiers or classes
swift test --filter Tier1FeatureTests
swift test --filter Tier2BoundaryTests
swift test --filter Tier3CombinationTests
swift test --filter Tier4ScenarioTests
```
