# Technical Review Record: swift-tailscale-client 1.0

**Document:** `Documentation/EXTERNAL-REVIEW.md`  
**Status:** In Progress / Open  
**Last Updated:** 2026-09-18  
**Scope:** Milestone 1–3 Architecture, Correctness, Framing, Resource Bounds, Concurrency, and Discovery  
**Authoritative Plan:** `Documentation/PLAN-1.0.md § W8` (Milestone 3, PR 14)  
**Gating Status:** **External review pending (adoption goal; not an independent 1.0 release blocker as of 2026-09-19)**

---

## 1. Review Overview & Objectives

In accordance with `Documentation/PLAN-1.0.md § W8`, blocking technical findings must be resolved before 1.0; independent external review remains a separate adoption goal. The review evaluates the core guarantees and invariants of `swift-tailscale-client`:

1. **Transport Framing & Socket Resource Bounds (W2: PR 04, PR 05)**
2. **Safe Configuration Writes & Concurrency Snapshot Control (W1: PR 02, PR 03)**
3. **Native Multi-Platform Discovery & Dynamic Credential Refresh (W4: PR 08, PR 09)**
4. **Bounded Observable Streaming & Reconnection Lifecycle (W3: PR 06, PR 07)**

---

## 2. Review Status & Retraction of Prior Attribution

> [!IMPORTANT]
> **Attribution Retraction**:
> Earlier drafts of this document attributed review completion to an external persona ("Dr. E. Aris Thorne, Principal Distributed Systems Architect"). That persona was synthetic and does not represent an independently verifiable human reviewer. This attribution is formally retracted.

### Current Review Posture:
1. **Automated & Adversarial Swarm Verification**: Completed. The codebase has undergone multi-agent challenger testing, forensic source audits, and stress testing across:
   - `UnixSocketFaultTests.swift`: Socket timeouts, broken pipes, truncation.
   - `TransportCancellationChallengerTests.swift`: Non-blocking socket polling and cooperative cancellation.
   - `ServeConfigLosslessTests.swift`: 64-bit integer preservation and unmodeled field round-trips.
   - `DiscoveryRecoveryTests.swift`: Single-flight rediscovery under concurrent caller stampedes.
2. **Independent External Review**: **OPEN / PENDING**. Review by a qualified engineer independent of this implementation has not yet been conducted. It remains an upstream-adoption goal, rather than a blocker for the independent release; the release consumer check is the actual NWX integration.

---

## 3. Subsystem Evaluation Criteria (For External Reviewers)

External reviewers evaluating the library for 1.0 clearance should inspect the following invariants:

### Subsystem 1: POSIX Unix Socket Transport & HTTP Framing
- **Files**: `Sources/TailscaleClient/Transport/` (`HTTPWireFormat.swift`, `ChunkedTransferDecoder.swift`, `UnixSocketTransport.swift`).
- **Invariants to Check**:
  - Unconditional 64 KiB head limit enforcement in `HTTPHeadBuffer.feed`.
  - Strict `Content-Length` and `ChunkedTransferDecoder.isComplete` validation on unary responses.
  - Lower-layer line bounds in `NewlineFramer` and unary response accumulation limits.
  - Cooperative POSIX socket cancellation and zero descriptor leaks.

### Subsystem 2: Safe Configuration Writes & Snapshot Concurrency
- **Files**: `Sources/TailscaleClient/Models/ServeConfig.swift`, `ServeConfigSnapshot.swift`, `JSONValue.swift`, `ServeAPI.swift`.
- **Invariants to Check**:
  - Lossless recursive preservation of unmodeled JSON fields.
  - Snapshot concurrency: `setServeConfig(_:matching:)` requires matching ETag.
  - Target binding: snapshots are bound to their originating target to prevent cross-daemon replay.
  - Unconditional writes restricted to `replaceServeConfigUnconditionally(_:)`.

### Subsystem 3: Discovery & Dynamic Credential Recovery
- **Files**: `Sources/TailscaleClient/Configuration/LocalAPIDiscovery.swift`, `EndpointSource.swift`, `TailscaleClientConfiguration.swift`.
- **Invariants to Check**:
  - macOS standalone `.pkg` discovery via `/Library/Tailscale/ipnport` symlink and file token.
  - App Store GUI discovery remains strictly opt-in (`allowMacOSAppStoreDiscovery: true`).
  - `.automatic` connections perform single-flight rediscovery on restart; `.pinned` connections remain immutable.
