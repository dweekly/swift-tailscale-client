# 1.0 Support Policy & Compatibility Matrix

Status: **1.0 Baseline Support Matrix**, 2026-09-17.
Authoritative documents: [PLAN-1.0.md](PLAN-1.0.md) | [DECISIONS-1.0.md](DECISIONS-1.0.md) | [endpoints.json](endpoints.json).

This document establishes the official platform, toolchain, and daemon compatibility matrix for `swift-tailscale-client` 1.0, along with the support lifecycle and security maintenance policy.

---

## 1. Supported Environments

### Swift Toolchains
| Swift Version | Concurrency Mode | Status |
|---|---|---|
| Swift 6.1 | Strict (`complete`) | **Supported** (Baseline, matching `swift-tools-version: 6.1`) |
| Swift 6.2 | Strict (`complete`) | **Supported** |

All public APIs require Swift 6 concurrency mode (`Sendable` annotations, actor isolation, and structured concurrency). Toolchain baseline is Swift 6.1+.

### Operating Systems & Architectures
| Operating System | Architectures | Daemon Runtime Support | Notes |
|---|---|---|---|
| **macOS 13.0+** (Ventura, Sonoma, Sequoia) | `arm64`, `x86_64` | **Full Support** | Unix domain sockets, standalone `.pkg`, App Store GUI (opt-in) |
| **Linux** (kernel 5.4+, glibc 2.31+ / musl) | `x86_64`, `aarch64` | **Full Support** | Unix domain socket (`/var/run/tailscale/tailscaled.sock`), loopback |
| **iOS 16.0+** | `arm64` | *Build Only* | Client models, requests, mocks; no daemon runtime |
| **tvOS 16.0+** | `arm64` | *Build Only* | Client models, requests, mocks; no daemon runtime |
| **watchOS 9.0+** | `arm64_32`, `arm64` | *Build Only* | Client models, requests, mocks; no daemon runtime |
| **visionOS 1.0+** | `arm64` | *Build Only* | Client models, requests, mocks; no daemon runtime |

---

## 2. Supported Tailscale Daemon Matrix

`swift-tailscale-client` interacts with an **already installed and running** `tailscaled` daemon over its LocalAPI.

| Daemon Track | Version Range | CI Status | Availability Guarantee |
|---|---|---|---|
| **Supported Floor** | `1.76.0` | Blocking gate | Minimum version supporting baseline status, prefs, and core APIs |
| **Mainline Supported** | `1.76.x` – `1.96.x` | Blocking gate | Full support for all stable endpoints in `endpoints.json` |
| **Latest Stable** | Latest release | Blocking gate | Continuously verified against official Tailscale stable releases |
| **Unstable / Nightly** | Upstream `main` | Non-blocking signal | Weekly automated drift detection; catches upcoming breaks early |

### Feature Availability and Older Daemons
When communicating with a daemon that does not implement an endpoint or feature (e.g. ACME certificates or DNS configuration on certain builds):
- The client throws typed `TailscaleClientError.endpointUnavailable(endpoint:feature:)`.
- Callers can inspect capability version negotiation via `TailscaleClient.versionDiagnostics()`.

---

## 3. Installation Flavors & Discovery Mechanisms

`LocalAPIDiscovery` automatically resolves LocalAPI endpoints across all standard Tailscale installation methods:

| Flavor | Method | Endpoint / Credentials | TCC Interaction |
|---|---|---|---|
| **macOS Standalone Daemon / Homebrew** | Unix socket | `/var/run/tailscaled.socket` or `/var/run/tailscale/tailscaled.sock` | None |
| **macOS Standalone App (`.pkg`)** | Symlink / File Token | `/Library/Tailscale/ipnport` symlink & `sameuserproof-<port>` (fallback `ipnport.token`) | None |
| **macOS App Store App (GUI)** | Group Containers / Loopback | Loopback port (`127.0.0.1:<port>`) with file token | **Opt-in only** (`allowMacOSAppStoreDiscovery: true`); triggers TCC prompt |
| **Linux Systemd** | Unix socket | `/var/run/tailscale/tailscaled.sock` | None |
| **Custom / Pinned** | Environment / Config | Explicit path, URL, or host/port | None |

### Credential Refresh & Daemon Restarts
- **Configuration Source Tracking (`EndpointSource`)**: Every configuration records whether its endpoint was resolved dynamically (`.automatic(LocalAPIDiscovery)`) or pinned explicitly by the caller (`.pinned(TailscaleEndpoint)`).
- **Automatic Clients** (`TailscaleClient()`, `.default`, or `TailscaleClient.discover(...)`):
  - On daemon restart, port reassignment (`ECONNREFUSED` / `socketNotFound`), or credential rotation (HTTP 401 / loopback 403), the client executes single-flight asynchronous re-discovery to refresh port and token material without probe stampedes.
  - **Mutation Safety Guarantee**: Idempotent requests (`GET`, `HEAD`) and connect-stage errors (where bytes were never written or daemon wasn't contacted) are safely replayed once after re-discovery. Mutating requests (`POST`, `PATCH`, `DELETE`) rejected with HTTP 401/403 are safely retried with the refreshed token, while ambiguous transport disconnects (e.g. mid-stream drops, connection resets, or timeouts) are never automatically replayed to prevent duplicate side effects.
- **Pinned Clients**: Connections created with explicit endpoints (`.unixSocket(path:)` or `.loopback(host:port:)`) are marked `.pinned` and strictly target the configured destination, reporting connection or credential failures directly without re-discovery.

---

## 4. Permissions & Privilege Model

LocalAPI permissions depend on daemon configuration and user context:

1. **Read-Only Endpoints**:
   - `status()`, `certDomains()`, `whois()`, `versionDiagnostics()`
   - Accessible by local unprivileged users who have read access to the daemon socket or proof token.
2. **Mutating Endpoints**:
   - `setServeConfig()`, `patchPrefs()`, `setDNS()`, `resetAuth()`
   - Require operator privileges. If the calling process does not have operator rights, the client surfaces HTTP 403 as typed `TailscaleClientError.permissionDenied(endpoint:)`.

---

## 5. Security and Redaction Policy

- **Token Protection**: Authentication tokens are strictly redacted from `CustomStringConvertible`, `CustomDebugStringConvertible`, and `CustomReflectable` implementations. They never appear in crash reports, logs, or error descriptions.
- **Header Auditing**: Requests can carry audit justifications via `TailscaleClient.withAuditReason(_:operation:)`, transmitted securely via `X-Tailscale-Reason`.
- **Reporting Vulnerabilities**: Report security issues directly to the maintainer via email: `david@weekly.org` (or review [SECURITY.md](../SECURITY.md)).

---

## 6. Stability and Maintenance Lifecycle

### Release Ownership & Governance Roles
- **Primary Release Owner**: David E. Weekly (`@dweekly`, [david@weekly.org](mailto:david@weekly.org)). Responsible for release management, architecture, tag signing, and security triage.
- **Designated Backup Maintainer**: [security-backup@weekly.org](mailto:security-backup@weekly.org). Empowered with repository admin permissions to triage security reports if the primary maintainer is unreachable (>48h for Critical incidents, >7 business days for releases), execute release rehearsals, and cut emergency patch releases.

### Tag Immutability & Emergency Rollback
- **Git Tag Immutability**: Published Git tags are **strictly immutable**. Once published, tags are never moved, rewritten, or deleted. In the Swift Package Manager ecosystem, moving a tag breaks consumer builds via `Package.resolved` fingerprint mismatch errors and corrupts index caches.
- **Emergency Patch Protocol**: If a release contains a critical bug or vulnerability, the release is marked as **Yanked** on GitHub Releases, and a fast-track patch release (`1.0.(x+1)`) is cut from the tag commit and published immediately.

### Versioning Policies
- **Semantic Versioning**: 1.0 adopts strict SemVer for all public types and symbols in `TailscaleClient`.
- **Patch Releases (1.0.x)**: Bug fixes, transport reliability enhancements, and documentation improvements. No breaking API changes.
- **Minor Releases (1.x.0)**: New LocalAPI endpoint wrappers and additive models. Backwards compatible.
- **Upstream Deprecations**: If upstream Tailscale deprecates an endpoint, the corresponding Swift method will be marked `@deprecated` with migration guidance for at least one minor release before removal in a major version.
