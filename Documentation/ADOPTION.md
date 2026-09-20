# Adoption Brief: swift-tailscale-client

**Canonical technical evaluation document for engineering teams, architecture review boards, and prospective integrators.**

`swift-tailscale-client` is an unofficial, production-grade Swift 6 client library and CLI utility for the Tailscale LocalAPI daemon. It provides strongly typed, memory-safe, and concurrency-hardened interfaces to observe and control local Tailscale installations on macOS and Linux.

---

## 1. Executive Summary

| Attribute | Specification |
|---|---|
| **Package Name** | `swift-tailscale-client` |
| **Primary Products** | `TailscaleClient` (core library), `TailscaleClientMocks` (test mocks), `tailscale-swift` (CLI) |
| **Language & Toolchain** | Swift 6.0+, strict concurrency (`Complete`), zero warnings |
| **Dependencies** | **Zero third-party package dependencies** (relies solely on standard Foundation and POSIX APIs) |
| **License** | MIT License (OSI-approved), Developer Certificate of Origin (DCO 1.1) provenance |
| **Supported Platforms** | **macOS 13.0+** (Ventura, Sonoma, Sequoia), **Linux** (kernel 5.4+, glibc 2.31+ / musl) |
| **Build-Only Platforms** | **iOS 16.0+**, **tvOS 16.0+**, **watchOS 9.0+**, **visionOS 1.0+** (models, serialization, mocks) |
| **Target Daemons** | Tailscale `1.76.0` through `1.98.0+` (verified across stable, previous-stable, and nightly builds) |

---

## 2. Intended Use Cases

`swift-tailscale-client` is purpose-built for applications that need to interact with the Tailscale daemon already present on the user's host machine:

1. **Diagnostic & Monitoring Tools**:
   - Querying real-time connection status, peer health, and backend states (`status()`).
   - Resolving peer identities and endpoint mappings (`whois(address:)`).
   - Running client-side STUN latency and NAT penetration diagnostics (`netcheck()`, `derpMap()`).
   - Inspecting MagicDNS configuration and querying tailnet records (`dnsOSConfig()`, `dnsQuery(name:)`).
   - Ingesting daemon runtime counters and user-facing Prometheus metrics (`metrics()`, `userMetrics()`).
   - *Reference Production Consumer*: **Network Weather (NWX)** macOS network diagnostics suite.

2. **Menu Bar & System Status Utilities**:
   - Lightweight status bar apps displaying current tailnet state and active exit nodes.
   - One-click exit node switching and toggle controls (`suggestExitNode()`, `setUseExitNode(enabled:)`).
   - Real-time event streaming over the IPN notification bus (`watchIPNBusEvents()`) without wasteful polling.
   - Quick tailnet disconnect, reconnect, and auth key bring-up (`start()`, `loginInteractive()`).

3. **Service Management & Reverse Proxies**:
   - Programmatic management of Tailscale Serve and Funnel configurations (`serveConfigSnapshot()`, `setServeConfig(_:matching:)`, `updateServeConfig(_:mutate:)`).
   - Automated provisioning and renewal monitoring of Tailnet TLS certificates (`certDomains()`, `certPair()`).
   - Multi-account switching and profile lifecycle management (`profiles()`, `switchProfile()`, `switchToEmptyProfile()`).

4. **CLI Utilities & Automation Scripts**:
   - Headless server provisioning scripts and CI/CD pipeline automation on Linux and macOS runners.
   - Native command-line tools built with Swift (such as the bundled `tailscale-swift` executable).

---

## 3. Architectural Boundary & Taxonomy

Choosing the correct integration tier is critical. Tailscale provides three distinct programming interfaces:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TAILSCALE INTEGRATION TIERS                        │
├──────────────────────┬──────────────────────┬───────────────────────────────┤
│    LocalAPI Client   │ Embedded Node (tsnet)│   Control Plane Admin API     │
│ swift-tailscale-client│     TailscaleKit     │       api.tailscale.com       │
├──────────────────────┼──────────────────────┼───────────────────────────────┤
│ Talks to existing    │ Embeds an isolated   │ Manages tailnet-wide          │
│ tailscaled daemon on │ WireGuard node inside│ configuration, devices, ACLs, │
│ localhost via socket │ the app process.     │ and users via SaaS REST API.  │
│ or loopback HTTP.    │                      │                               │
├──────────────────────┼──────────────────────┼───────────────────────────────┤
│ Requires Tailscale   │ No host installation │ No host installation          │
│ installed on host.   │ required; standalone.│ required; server-to-cloud.    │
├──────────────────────┼──────────────────────┼───────────────────────────────┤
│ Inspects host state, │ Has its own distinct │ Manages policy, keys,         │
│ peers, Serve/Funnel, │ node identity, IP,   │ DNS nameservers,              │
│ and IPN bus events.  │ and tailnet keys.    │ and device authorization.     │
├──────────────────────┼──────────────────────┼───────────────────────────────┤
│ Zero external deps;  │ Large binary/memory  │ Standard HTTPS client;        │
│ native Swift actor.  │ footprint (C/Go).    │ requires OAuth/API token.     │
└──────────────────────┴──────────────────────┴───────────────────────────────┘
```

- **Use `swift-tailscale-client` when**: You want your app to observe, integrate with, or configure the Tailscale installation the user already uses on their Mac or Linux system.
- **Do NOT use this package when**:
  - Your app must run on iOS or a locked-down container where Tailscale cannot be installed as an OS daemon (use `TailscaleKit` instead).
  - You need to automate tailnet-wide ACL rules, invite team members, or generate pre-authenticated keys from a central backend (use the Tailscale Admin REST API instead).

---

## 4. Contractual Guarantees

`swift-tailscale-client` is engineered to production standards with strict runtime guarantees:

### 4.1 Strict Swift 6 Concurrency
- 100% compiled under Swift 6 language mode with complete concurrency checking.
- The primary entry point `TailscaleClient` is an `actor`, eliminating data races and protecting internal transport states.
- Every public data model, enum, and error struct conforms to `Sendable`.
- Stream callbacks and observer closures are explicitly annotated `@Sendable`.

### 4.2 Lossless JSON Round-Tripping for Configurations
- Upstream Tailscale frequently adds new fields to `ServeConfig`. Traditional decoders drop unknown keys, causing edits to silently erase unmodeled configuration on the daemon.
- `ServeConfig` and all child types (`TCPPortHandler`, `WebServerConfig`, `HTTPHandler`, `ServiceConfig`) retain unmodeled JSON fields recursively using type-safe `JSONValue` containers.
- 64-bit integer values are preserved with full bit-level fidelity (preventing IEEE 754 floating-point precision loss).
- Safe conditional writes default to mandatory ETag verification via `ServeConfigSnapshot`. A stale write fails with typed `.preconditionFailed` (HTTP 412) rather than overwriting concurrent edits.
- Intentional overwrites require calling the explicitly named `replaceServeConfigUnconditionally(_:)`.

### 4.3 Bounded Resource Allocation & DoS Defense
- **HTTP Head Limits**: `HTTPHeadBuffer` unconditionally enforces a 64 KiB ceiling before parsing headers, preventing memory exhaustion attacks from misbehaving sockets.
- **Message Framing**: Strict unary response validation rejects truncated responses where byte counts do not match `Content-Length`. Chunked streams require full completion sequences before termination.
- **Streaming Buffers**: The IPN bus stream uses explicit bounded queue policies (`.bounded(capacity:overflowPolicy:)`). When consumer tasks fall behind, the client emits `.stateGap(reason:)` events or errors rather than permitting unbounded heap growth or silent data loss.
- **Backoff & Jitter**: Automated stream reconnects follow a classified exponential backoff strategy with randomized jitter and hard duration caps.

### 4.4 Zero Socket Descriptor Leaks
- Sockets in `UnixSocketTransport` adhere to single-ownership RAII patterns.
- Sockets are closed exactly once across all execution branches: successful completion, end-of-file, network faults, and Swift `Task` cancellation.
- Verified by automated adversarial fault injection tests asserting baseline file descriptor counts over 100+ rapid connect/cancel cycles.

### 4.5 Compiler-Enforced API Stability
- Public API surfaces are audited against an approved symbol graph baseline using `swift package diagnose-api-breaking-changes`.
- Unintentional source-breaking or ABI-breaking modifications fail CI automatically.
- Authored public API documentation coverage is maintained at 100% with DocC `--warnings-as-errors`.

---

## 5. Compatibility Evidence & Verification Matrix

The package's reliability is backed by empirical verification against real Tailscale daemons:

| Compatibility Axis | Target Range | Verification Mechanism |
|---|---|---|
| **Daemon Versions** | `1.76.0` – `1.98.0+` | Automated CI matrix testing against containerized and live tailscaled daemons |
| **Go Parity** | Protocol Capability Level `144` | Differential conformance harness (`Scripts/conformance-harness.go`) asserting parity with Go `client/local` |
| **Fixtures** | Versioned real responses | Sanitized JSON fixture suite (`Tests/TailscaleClientTests/Fixtures/`) recorded from live daemons |
| **macOS Runtimes** | macOS 13, 14, 15 (arm64 & x86_64) | Tested on macOS bare metal runners across standalone `.pkg`, Homebrew, and GUI flavors |
| **Linux Runtimes** | Ubuntu 22.04, 24.04, Debian 12 | Headless CI verification over systemd sockets (`/var/run/tailscale/tailscaled.sock`) |

---

## 6. Known Limitations & Operational Constraints

1. **Host Daemon Requirement**:
   - The package cannot function if `tailscaled` is not installed and running on the target machine. If the daemon is inactive, calls throw `TailscaleClientError.transport(.socketNotFound)`.
2. **macOS App Store Sandboxing & TCC**:
   - The Mac App Store variant of Tailscale runs within an App Sandbox and stores its credentials inside an Application Group container (`io.tailscale.ipn.macsys`).
   - Accessing this container triggers a system TCC prompt: *"App wants to access data from Tailscale"*.
   - To prevent unexpected prompts, `LocalAPIDiscovery` defaults strictly to Unix domain sockets. Discovery of the App Store GUI daemon is **opt-in only** via `TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)`.
3. **Third-Party App Sandboxing**:
   - Third-party sandboxed macOS applications must declare network client entitlements (`com.apple.security.network.client`) and appropriate temporary file-read permissions if connecting via loopback or Unix domain sockets.
4. **Daemon Feature Modularity**:
   - Tailscale daemons built without specific compile flags (e.g. ACME certificates or debug endpoints) return HTTP 404 for omitted features. The client surfaces these as typed `TailscaleClientError.endpointUnavailable(endpoint:feature:)`.
5. **Privilege Model**:
   - Read-only endpoints (`status`, `whois`) require standard local read permissions on the socket. Mutating endpoints (`setServeConfig`, `editPrefs`, `resetAuth`) require operator-level access; non-operator calls throw typed `.permissionDenied`.

---

## 7. Maintenance Burden & Supply Chain Hygiene

- **Self-Contained SPM Package**: Zero external package dependencies for the core library. Integrating `swift-tailscale-client` introduces no transitive dependency risks, no binary blobs, and no C bridge headers.
- **Decoupled Test Product**: Testing consumer applications is supported by `TailscaleClientMocks`, an independent product containing `MockTransport` and scriptable event stream generators.
- **Strict Contribution Hygiene**: 100% of commits require Developer Certificate of Origin (DCO 1.1) sign-offs (`git commit -s`).
- **Security SLA**: Committed security response targets defined in `SECURITY.md` (48-hour initial triage, 14-day critical patch window, 12-month security maintenance on 1.0.x branches).
- **Maintainer Redundancy**: Primary maintainer David E. Weekly (`@dweekly`) with documented backup release ownership and release checklists.

---

## 8. Sample Integration

```swift
import Foundation
import TailscaleClient

@main
struct MonitorExample {
  static func main() async throws {
    // 1. Initialize client with automatic LocalAPI discovery
    let client = TailscaleClient()

    // 2. Fetch local daemon status
    let status = try await client.status()
    print("Connected to tailnet: \(status.currentTailnet?.name ?? "unknown")")
    print("Self IP: \(status.selfNode?.tailscaleIPs.first ?? "unknown")")

    // 3. Lossless Serve configuration update with ETag optimistic concurrency
    let snapshot = try await client.serveConfigSnapshot()
    var config = snapshot.config
    config.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")

    do {
      let updatedSnapshot = try await client.setServeConfig(config, matching: snapshot)
      print("Serve config successfully updated! New ETag: \(updatedSnapshot.etag)")
    } catch TailscaleClientError.preconditionFailed {
      print("Concurrent modification detected; re-fetching snapshot before retry.")
    }

    // 4. Stream real-time IPN bus events with automatic backoff reconnection
    let eventStream = try await client.watchIPNBusEvents(
      options: [.initialState, .initialHealthState],
      retryPolicy: .default
    )

    for try await event in eventStream {
      switch event {
      case .notification(let notify):
        if let backendState = notify.state {
          print("Tailscale daemon state changed to: \(backendState)")
        }
      case .lifecycle(let status):
        print("IPN Bus connection lifecycle: \(status)")
      }
    }
  }
}
```

---

## 9. Tailscale Community Projects Submission Draft

### Project Metadata
- **Project Name**: `swift-tailscale-client`
- **Repository URL**: `https://github.com/dweekly/swift-tailscale-client`
- **Primary Category**: Tools / Interfaces
- **License**: MIT License (OSI-approved)
- **Primary Maintainer**: David E. Weekly (`@dweekly`)
- **Package Ecosystem**: Swift Package Manager (SPM)
- **Platforms**: macOS 13.0+, Linux (Runtime); iOS, tvOS, watchOS, visionOS (Build/Models)

### Short Description (for Catalog Card)
An idiomatic, zero-dependency Swift 6 client library and CLI for the Tailscale LocalAPI daemon. Enables macOS and Linux developers to build diagnostic utilities, menu bar helpers, and service automation that interact with local Tailscale installations.

### Long Description
`swift-tailscale-client` provides a strongly typed, memory-safe, and concurrency-hardened interface to communicate with an already-running Tailscale daemon over its LocalAPI (Unix domain socket or loopback HTTP).

While embedded solutions like TailscaleKit embed a new WireGuard node inside an app, `swift-tailscale-client` fills the critical niche of observing and controlling the user's *existing* host Tailscale installation. It powers real-time status monitoring, STUN latency diagnostics, MagicDNS inspection, multi-account profile switching, and safe Serve/Funnel reverse-proxy management.

Engineered for strict Swift 6 concurrency, the package features 100% `Sendable` types, lossless JSON round-tripping for Serve configurations, bounded streaming queues for the IPN bus, zero descriptor leaks, and an automated differential conformance test harness verified against Tailscale daemon versions 1.76.0 through 1.98.0+.

### Key Features
- **Zero External Dependencies**: Implemented in pure Swift using Foundation and POSIX APIs; no C bridges or external package dependencies.
- **Multi-Platform LocalAPI Discovery**: Automatically resolves Homebrew sockets, standalone `.pkg` app symlinks (`/Library/Tailscale/ipnport`), and Linux systemd sockets.
- **Safe Configuration Updates**: Optimistic concurrency (ETag) enforcement on Serve/Funnel updates with recursive preservation of unmodeled daemon settings.
- **Resilient Real-Time Streaming**: Asynchronous event streams for the IPN notification bus with bounded memory buffers and classified reconnect backoff.
- **Comprehensive Test Suite**: Shipped with `TailscaleClientMocks` for unit testing consumer apps without requiring a live daemon.
- **Production Provenance**: Shipped with Developer Certificate of Origin (DCO) commit trailers and a 12-month security patch commitment on 1.0.x branches.

### Installation Snippet (Package.swift)
```swift
dependencies: [
  .package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "1.0.0")
],
targets: [
  .target(
    name: "MyTailscaleApp",
    dependencies: [
      .product(name: "TailscaleClient", package: "swift-tailscale-client")
    ]
  ),
  .testTarget(
    name: "MyTailscaleAppTests",
    dependencies: [
      .product(name: "TailscaleClientMocks", package: "swift-tailscale-client")
    ]
  )
]
```

### Usage Example
```swift
import TailscaleClient

let client = TailscaleClient()

// Fetch daemon status and peers
let status = try await client.status()
print("Tailscale Node: \(status.selfNode?.hostName ?? "unknown")")

// Stream IPN bus notifications
for try await event in try await client.watchIPNBusEvents(options: [.initialState]) {
  if case .notification(let notify) = event, let state = notify.state {
    print("Daemon state: \(state)")
  }
}
```

### Maintenance & Security Statement
The project is actively maintained with continuous integration testing across macOS and Linux, verifying compatibility against Tailscale stable, previous-stable, and nightly daemon builds. Security issues are triaged within 48 hours in accordance with `SECURITY.md`.

### Compliance & Trademark Disclaimer
`swift-tailscale-client` is an independent, community-driven open source project and is not affiliated with, endorsed by, or sponsored by Tailscale Inc. All references to Tailscale and WireGuard are descriptive of compatibility and adhere to Tailscale brand guidelines.

---

## 10. Upstream Collaboration Strategy & Non-Blocking Release Policy

Authoritative Reference: `Documentation/PLAN-1.0.md § W8`, `ROADMAP.md`

### 10.1 Collaboration Philosophy
`swift-tailscale-client` exists to enrich the Tailscale developer ecosystem by providing a native, idiomatic Swift client for Apple and Linux environments. Our engagement with Tailscale Inc. is structured around mutual technical respect, clear architectural boundaries, and low coordination overhead.

We recognize three distinct tiers of upstream engagement:
1. **Community Catalog Listing**: Intermediate discovery for developers.
2. **Technical Dialogue & Architecture Feedback**: Targeted reviews of shared boundaries.
3. **Potential Future Official Adoption**: Long-term upstream adoption if desired by Tailscale.

### 10.2 The Three Engagement Tiers

#### Tier 1: Community Catalog Listing
- **Goal**: Publish `swift-tailscale-client` in the official Tailscale Community Projects catalog under the *Tools* / *Interfaces* categories.
- **Channel**: Submit the formal submission draft via the community submission process.
- **Positioning**: Clearly marked as an unofficial community tool maintained by David E. Weekly and contributors.
- **Value to Tailscale**: Highlights Apple ecosystem support, demonstrates Swift 6 best practices, and directs developers to an actively maintained client.

#### Tier 2: Targeted Technical Dialogue & Design Feedback
- **Goal**: Solicit design validation from Tailscale engineers who maintain `client/local` and `ipn/localapi` on specific boundary issues where changes are cheap.
- **Engagement Ground Rules**:
  - Do *not* ask for broad organizational endorsement.
  - Do *not* submit speculative, massive pull requests to upstream repositories.
  - Present bounded questions or focused integration evaluation branches (e.g., verifying `sameuserproof` token fallback ordering, ETag concurrency edge cases in `serve-config`, or IPN bus response head metadata framing).
  - Share sanitized reproduction cases for any daemon edge cases discovered by our differential test harness.

#### Tier 3: Upstream Evolution & Potential Official Adoption
- **Goal**: Ensure the repository is maintained in a pristine, enterprise-ready state such that if Tailscale ever decides to maintain an official Swift LocalAPI client, repository transfer or code adoption is legally and technically effortless.
- **Pre-Emptive Measures Maintained in Repository**:
  - **License & Provenance**: Clean MIT license. Every git commit requires a Developer Certificate of Origin (DCO 1.1) trailer (`Signed-off-by: Name <email>`).
  - **Zero External Dependencies**: Pure Swift standard library and POSIX APIs; no external package baggage.
  - **Documentation & Tests**: 100% authored DocC coverage, comprehensive regression suites, and Go differential conformance tests.
  - **Package Structure**: Clean SPM layout matching Apple and Tailscale packaging standards.

### 10.3 Explicit Non-Blocking Release Criteria

A foundational principle of Milestone 3 and the 1.0 Release Plan is autonomy:

> **Tailscale Inc. endorsement, review, response, or community catalog listing is strictly NOT a release gate for `swift-tailscale-client` 1.0.0.**

#### Rationale:
1. **Consumer Schedules**: Downstream consumers (including Network Weather / NWX and independent developers) require a production-ready, SemVer-protected 1.0 library on predictable milestones.
2. **Upstream Priorities**: Tailscale Inc. engineers have internal roadmap priorities. Waiting for an upstream corporate review cycle introduces unbounded schedule latency.
3. **Self-Contained Verification**: The correctness, security, and stability of `swift-tailscale-client` 1.0 are verified by our own automated test suites, fault injection harnesses, real daemon matrices, and independent consumer soak tests (Gates G1 through G8).

#### Operational Protocol:
- Work Item W8 authorizes the **preparation** and **formatting** of adoption briefs, community project submissions, and outreach collateral.
- Outbound communications or community submissions can proceed asynchronously when maintainer David E. Weekly chooses.
- An unread email, pending submission review, or absence of response from Tailscale Inc. shall **never** delay the completion of Milestone 3, the cut of Release Candidate 1.0.0-rc.1, or the final 1.0.0 release publication.
