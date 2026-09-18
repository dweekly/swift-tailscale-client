# Consumer Integration & Simulation Report (Pre-1.0 Candidate)

**Evaluation Scope:** In-Tree Consumer Architecture Simulations  
**Target Release:** `v1.0.0-rc` (Pre-release Candidate)  
**Evaluated Consumer Archetypes:**  
1. **Network Weather (NWX)**: Menu-bar status widget & diagnostics daemon (Read-Heavy / Continuous Streaming)  
2. **TailscaleFleetAgent**: Infrastructure provisioning & reverse proxy agent (Active Mutation / Profile Management)  
**Authoritative Invariants:** `Documentation/PLAN-1.0.md § W8 & § 5`, `Documentation/CONSUMER-VALIDATION.md`  
**Gating Status:** **Gate G8 / G9 OPEN / INCOMPLETE (Simulated In-Tree Tests Passed; Independent Production Trial Pending)**

---

## 1. Executive Summary

To prepare for **Gate G8 (Consumer Validation)** and **Gate G9 (Release Candidate)** of the 1.0 Release Plan, `swift-tailscale-client` was evaluated against two representative consumer workload archetypes implemented as comprehensive in-tree test suites in `Tests/TailscaleClientTests/ConsumerValidation/`:
- `NWXConsumerMigrationTests.swift`: Models read-heavy diagnostics, async discovery, streaming IPN bus consumption, sleep/wake reconnect gaps, and UI thread backpressure.
- `FleetAgentConfigurationTests.swift`: Models mutation-heavy infrastructure management, profile switching, masked preference patching, and optimistic concurrency Serve/Funnel updates.

> [!IMPORTANT]
> **Status of Production Trial**:
> The committed consumer test suites run as automated in-tree simulations using strictly public APIs without `@testable` imports. An independent, multi-week production trial with real-world consumer codebases (such as production deployments of Network Weather) and external operator sign-offs remains **open and pending**. Gates G8 and G9 remain open until real consumer commits and independently attributable production evidence are collected.

---

## 2. In-Tree Consumer Simulation Profiles

### 2.1 Network Weather (NWX) Simulation
- **File**: `Tests/TailscaleClientTests/ConsumerValidation/NWXConsumerMigrationTests.swift`
- **Role**: Lightweight macOS menu bar utility providing continuous network mesh topology, exit node status, and DERP relay latency telemetry.
- **Integration Surface**: Strictly public APIs via `LocalAPIDiscovery.discoverAsync()`, `TailscaleClient.watchIPNBusEvents()`, `TailscaleClient.status()`, and `TailscaleClient.netcheck()`. Zero `@testable` imports.
- **Scenarios Verified**:
  - `testContinuousIPNBusStreaming`: Verifies consumption of IPN notifications and transition to `.connected` lifecycle state.
  - `testSleepWakeDisconnectAndGapRecovery`: Verifies that socket severance produces `.disconnected`, reconnection triggers `.retrying` with backoff, and state resynchronization fires `.stateGap(reason: "reconnected")`.
  - `testStateGapTriggersBaselineStatusRefresh`: Verifies that receiving `.stateGap` prompts consumer state invalidation and full `status()` refresh.
  - `testDaemonRestartRediscovery`: Verifies that connection failure during daemon restart triggers single-flight dynamic rediscovery of loopback port and token.
  - `testBackpressureQueueOverflow`: Verifies that consumer UI thread delays cause the bounded queue (256 events) to emit `.stateGap(reason: "buffer_overflow")` without unbounded memory accumulation.

### 2.2 TailscaleFleetAgent Simulation
- **File**: `Tests/TailscaleClientTests/ConsumerValidation/FleetAgentConfigurationTests.swift`
- **Role**: Server provisioning daemon managing reverse proxies, Funnel TLS endpoints, and multi-tenant Tailscale profiles across developer workstations and cloud hosts.
- **Integration Surface**: Strictly public APIs via `TailscaleClient.serveConfigSnapshot()`, `TailscaleClient.setServeConfig(_:matching:)`, `TailscaleClient.replaceServeConfigUnconditionally()`, and `TailscaleClient.switchProfile()`. Zero `@testable` imports.
- **Scenarios Verified**:
  - `testSafeConcurrentServeUpdates`: Verifies that concurrent edits to `ServeConfig` are caught by ETag mismatch (HTTP 412 `.preconditionFailed`), preventing lost updates.
  - `testLosslessUnmodeledFieldPreservation`: Verifies that unrecognized daemon fields in ServeConfig survive round-trip mutation without schema loss.
  - `testProfileSwitching`: Verifies switching profiles and migrating to `switchToEmptyProfile()`.
  - `testMaskedPrefsSelectiveUpdate`: Verifies that `patchPrefs` updates only designated fields via `MaskedPrefs`.

---

## 3. Retraction of Unsupported Prior Claims

Earlier drafts of this report claimed a completed 14-day production trial from September 4–18, 2026, with over 1.2 million production events and signed third-party endorsements. 

**These claims are formally retracted:**
- The functionality under test was authored and integrated on September 17–18, 2026; no multi-week production deployment occurred prior to this date.
- Metrics reported in prior drafts (e.g. 874,210 NWX events, 4,280 fleet updates) were synthetic test counts, not observations from deployed production environments.
- Quoted endorsements attributed to consumer leads were narrative drafts and do not represent independently attributable third-party sign-offs.

---

## 4. Current Gating Verdict

- **Automated In-Tree Simulation**: **PASSED** (all consumer simulation tests execute cleanly with zero failures and zero `@testable` access).
- **Gate G8 (Consumer Validation)**: **INCOMPLETE / OPEN** (requires deployment in an independent consumer repository with attributable maintainer confirmation).
- **Gate G9 (Release Candidate)**: **INCOMPLETE / OPEN** (requires soak testing against an actual running Swift process and real release evidence).
