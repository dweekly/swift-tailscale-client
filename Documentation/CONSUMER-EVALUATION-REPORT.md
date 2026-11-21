# Consumer Integration & Simulation Report

**Evaluation Scope:** In-tree consumer simulation suites, plus one real-consumer smoke test  
**Release:** `v1.0.0` (published 2026-09-20)  
**Consumer Archetypes:**  
1. **Network Weather (NWX)**: Real macOS menu-bar diagnostics app (read-heavy, continuous streaming)  
2. **TailscaleFleetAgent**: Hypothetical configuration-management agent, simulated in-tree only (mutation, profile management)  
**Related documents:** `Documentation/PLAN-1.0.md § W8 & § 5`, `Documentation/CONSUMER-VALIDATION.md`  
**Gate status:** G8 met in narrowed form (NWX adapter smoke); no production trial has been run. See [`releases/1.0.0.md`](releases/1.0.0.md).

---

## 1. Summary

`swift-tailscale-client` is exercised against two consumer archetypes implemented as in-tree test suites in `Tests/TailscaleClientTests/ConsumerValidation/`. Both use only public APIs (no `@testable` import) and run against `MockTransport`, not a daemon:

- `NWXConsumerMigrationTests.swift`: read-heavy diagnostics, async discovery, IPN bus streaming, lifecycle transitions, gap-triggered baseline refresh, and daemon-restart rediscovery.
- `FleetAgentConfigurationTests.swift`: profile switching, masked preference updates, and optimistic-concurrency Serve updates.

Separately, NWX's real Tailscale adapter code passed a focused local read-only smoke test against this package on 2026-09-19 ([`releases/1.0.0.md` § 4](releases/1.0.0.md#4-nwx-adapter-smoke--2026-09-19)). That is not a full app build, an end-to-end UI test, or a production soak.

No multi-week production trial with a real consumer and no third-party sign-off has taken place.

---

## 2. In-Tree Consumer Simulation Profiles

### 2.1 Network Weather (NWX) Simulation
- **File**: `Tests/TailscaleClientTests/ConsumerValidation/NWXConsumerMigrationTests.swift`
- **Integration Surface**: Public APIs including `LocalAPIDiscovery.discoverAsync()`, `TailscaleClient.watchIPNBusEvents()`, `TailscaleClient.status()`, and `TailscaleClient.netcheck()`.
- **Tests**:
  - `testAsynchronousDiscovery`
  - `testInitialBaselineSeeding`
  - `testContinuousIPNBusStreaming`
  - `testLifecycleTransitionsEmitted`
  - `testStateGapTriggersBaselineStatusRefresh`
  - `testDaemonRestartRediscovery`

### 2.2 TailscaleFleetAgent Simulation
- **File**: `Tests/TailscaleClientTests/ConsumerValidation/FleetAgentConfigurationTests.swift`
- **Integration Surface**: Public APIs including `TailscaleClient.serveConfigSnapshot()`, `TailscaleClient.setServeConfig(_:matching:)`, `TailscaleClient.replaceServeConfigUnconditionally(_:)`, `TailscaleClient.switchProfile(_:)`, and `TailscaleClient.switchToEmptyProfile()`.
- **Tests**:
  - `testProfileSwitching`
  - `testCleanSlateEmptyProfileCreation`
  - `testMaskedPreferencesIsolation`
  - `testServeConfigConflictDetectionAndRetry`
  - `testLosslessUnmodeledFieldPreservation`
  - `testUnconditionalReplacement`

What each test verifies is described in [`CONSUMER-VALIDATION.md` § 6](CONSUMER-VALIDATION.md#6-automated-verification-matrix).

---

## 3. Status

- **In-tree simulation suites**: Part of the macOS unit test target; the required macOS lanes passed on the v1.0.0 tag commit (CI run 35543963700).
- **NWX adapter smoke**: Passed locally, read-only, 2026-09-19.
- **Production trial with a real consumer**: Not run. Additional consumers and a multi-week trial are adoption goals, not release gates.
- **Consumer soak**: Not run. See [`SOAK-VERIFICATION.md`](SOAK-VERIFICATION.md).
