# 1.0 Public Contract Decisions (W0)

Status: **Settled contract decisions**, 2026-09-17.
Authoritative context: [PLAN-1.0.md](PLAN-1.0.md) | [INTEGRATING.md](INTEGRATING.md) | [endpoints.json](endpoints.json).

This document records the design decisions required by Work Item W0 to freeze the public contract for `swift-tailscale-client` 1.0. These decisions govern safe configuration updates, streaming lifetime and observation, transport boundaries, credential discovery/recovery, experimental API compatibility, diagnostics scope, and supported environments.

---

## Decision 1: Serve Writes — Snapshot Concurrency and Lossless Field Preservation

### Problem Statement
In `0.12.0`, `TailscaleClient.setServeConfig(_ config: ServeConfig)` sends `config.etag` as the `If-Match` HTTP header. If `etag` is nil or empty, it sends an empty `If-Match` header, which writes unconditionally without precondition checks. Furthermore, `ServeConfig` is a mutable struct carrying both editable fields (`tcp`, `web`, `services`, `allowFunnel`, `foreground`) and the concurrency token (`etag`). If a caller creates a fresh `ServeConfig()`, `etag` is `nil`, leading to accidental unconditional overwrites. Finally, `ServeConfig`'s `Codable` implementation drops any JSON keys not explicitly declared in Swift, meaning edits to known fields erase newly added or unmodeled upstream daemon settings.

### Decision
1. **Separation of Concurrency Snapshot and Configuration**:
   - Introduce `ServeConfigSnapshot`: an immutable wrapper representing a fetched snapshot from a specific daemon target. It encapsulates the daemon's concurrency token (ETag), read timestamp, and the configuration payload.
   - `ServeConfig`: remains the editable configuration data model.
2. **Safe Conditional Writes as the Default**:
   - The primary write method requires both the snapshot and the desired updated configuration:
     ```swift
     public func setServeConfig(
       _ newConfig: ServeConfig,
       matching snapshot: ServeConfigSnapshot
     ) async throws -> ServeConfigSnapshot
     ```
     Or convenience mutation on the snapshot:
     ```swift
     public func updateServeConfig(
       _ snapshot: ServeConfigSnapshot,
       mutate: (inout ServeConfig) throws -> Void
     ) async throws -> ServeConfigSnapshot
     ```
   - If the daemon returns HTTP 412 (Precondition Failed), the client throws typed `TailscaleClientError.preconditionFailed(body:endpoint:)`.
   - If `snapshot` lacks an ETag (e.g., daemon returned no ETag header), `setServeConfig(_:matching:)` fails with a typed error (`TailscaleClientError.missingConcurrencyToken`) rather than silently downgrading to an unconditional write.
3. **Explicit Unconditional Replacement Operation**:
   - Intentional full replacement (such as initial provisioning or explicit force-resets) is isolated to a distinct, explicitly named API:
     ```swift
     public func replaceServeConfigUnconditionally(_ config: ServeConfig) async throws
     ```
   - This makes unconditional destruction of concurrent edits an explicit caller choice that stands out in code review.
4. **Lossless Field Preservation**:
   - `ServeConfig` and its nested types (`TCPPortHandler`, `WebServerConfig`, `HTTPHandler`, `ServiceConfig`) recursively retain unmodeled JSON keys in an internal dictionary preserving raw JSON types (`JSONValue` / preserved data nodes).
   - Unknown numeric values preserve integer vs. floating-point representations without loss of 64-bit precision.
   - On re-encoding, unknown keys are preserved alongside modified known fields.

### Consumer Sketch
```swift
// Safe read-modify-write:
let snapshot = try await client.serveConfigSnapshot()
var config = snapshot.config
config.tcp[8080] = TCPPortHandler(tcpForward: "127.0.0.1:3000")

do {
  let newSnapshot = try await client.setServeConfig(config, matching: snapshot)
  print("Updated serve config with ETag: \(newSnapshot.etag)")
} catch TailscaleClientError.preconditionFailed {
  print("Config changed concurrently; re-fetch and retry")
}

// Explicit unconditional overwrite (for tests or fresh initialization):
try await client.replaceServeConfigUnconditionally(config)
```

### Alternatives Considered & Rejected
- *Retain mutable `var etag: String?` on `ServeConfig`:* Rejected because callers constructing a default `ServeConfig()` accidentally perform unconditional overwrites without warning.
- *Automatic retry inside `setServeConfig`:* Rejected because mutations cannot be automatically replayed without knowing the caller's merge intent; three-way merges require domain-specific logic.

### Migration Implications
- `client.serveConfig()` is deprecated in favor of `client.serveConfigSnapshot()`.
- Existing `client.setServeConfig(config)` is deprecated; existing callers pass `matching: snapshot` or migrate to `replaceServeConfigUnconditionally(config)`.

---

## Decision 2: Streaming Transport — Response Metadata, Framing, and Cancellation

### Problem Statement
`UnixSocketTransport` and `URLSessionTailscaleTransport` stream bodies without exposing the HTTP response headers or status code prior to yielding body chunks. Unary Unix transport did not validate `Content-Length` or require chunk decoder completion (`isComplete`), and `HTTPHeadBuffer` bypassed size enforcement when `\r\n\r\n` was already in the buffer.

### Decision
1. **Response Metadata Delivery Prior to Stream Iteration**:
   - Transport streaming returns response head metadata before body bytes are iterated:
     ```swift
     public struct StreamingResponse: Sendable {
       public let statusCode: Int
       public let headers: [String: String]
       public let body: AsyncThrowingStream<Data, Error>
     }
     ```
   - Status checks, `Tailscale-Version` header observation, and `Tailscale-Cap` negotiation are verified *before* the consumer begins iterating the body stream.
2. **Internal HTTP Framing**:
   - Low-level framing (`ChunkedTransferDecoder`, `NewlineFramer`, `HTTPHeadBuffer`) remains internal to `TailscaleClient`.
   - Streaming endpoints yield unparsed JSON data lines or decoded model events.
3. **Strict Framing Validation**:
   - `HTTPHeadBuffer` enforces `maxHeadBytes = 64 * 1024` unconditionally, throwing `TailscaleTransportError.malformedResponse` if the accumulated head exceeds 64 KiB regardless of whether delimiter `\r\n\r\n` is present.
   - Unary responses strictly validate `Content-Length` (throwing on truncated bodies) and require `ChunkedTransferDecoder.isComplete == true` before returning `TailscaleResponse`.
4. **Cooperative Cancellation and Resource Ownership**:
   - Socket file descriptors are tracked with single-ownership semantics and closed on cancellation, normal completion, or error.
   - Non-blocking polling (`waitReadable`) checks `Task.isCancelled` on every cycle with bounded timeouts (≤ 500 ms).

### Consumer Sketch
```swift
// Internal transport contract:
let streamResp = try await transport.sendStreaming(request, capabilityVersion: cap)
guard streamResp.statusCode == 200 else {
  throw TailscaleClientError.unexpectedStatus(code: streamResp.statusCode, ...)
}
for try await line in streamResp.body {
  // process line
}
```

### Alternatives Considered & Rejected
- *Exposing raw byte streams / URLSession streams to public API:* Rejected because callers should not write HTTP framing decoders; the client library owns parsing LocalAPI framing.

---

## Decision 3: Monitoring — Connection Lifecycle, Gap Reporting, and Bounded Buffers

### Problem Statement
`watchIPNBus` provides a stream of `IPNNotify` updates. If the consumer is slow or the connection drops and reconnects, callers have no way to distinguish a quiet network from a broken socket, cannot observe reconnect backoff, and memory can accumulate unboundedly.

### Decision
1. **Explicit Lifecycle and Observation**:
   - Monitoring introduces a stream element that encapsulates either a daemon notification or an explicit lifecycle/gap event:
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
     ```
   - For backwards compatibility, convenience methods provide a filtered sequence yielding purely `IPNNotify` elements while logging or handling gaps according to a configurable overflow policy.
2. **Bounded Buffer Policy**:
   - Streams enforce a bounded queue (default: 256 events or 16 MB retained memory).
   - If a slow consumer causes buffer overflow: the stream does not silently discard events via `bufferingNewest(1)`. Instead, it emits `.lifecycle(.stateGap(reason: "buffer_overflow"))` or throws `TailscaleClientError.streamOverflow`, signaling the consumer that state is invalid and a fresh snapshot must be fetched.
3. **Deterministic Reconnect & Backoff**:
   - Transient disconnects retry with capped exponential backoff and jitter (e.g. 100 ms up to 10 s).
   - Permanent errors (HTTP 401 Unauthorized, HTTP 403 Forbidden, socket not found on non-managed paths) terminate immediately without retrying.

### Consumer Sketch
```swift
// Full event monitoring with lifecycle:
for try await event in client.watchIPNBusEvents() {
  switch event {
  case .notification(let notify):
    if let netMap = notify.netMap { updatePeers(netMap.peers) }
  case .lifecycle(.connected):
    print("IPN Bus connected")
  case .lifecycle(.disconnected(let reason)):
    print("Disconnected: \(reason)")
  case .lifecycle(.stateGap):
    // Refresh baseline status after gap
    let status = try await client.status()
    resetState(status)
  case .lifecycle(.retrying(let attempt, let delay)):
    print("Reconnecting in \(delay) (attempt \(attempt))")
  }
}
```

### Alternatives Considered & Rejected
- *Silent `bufferingNewest(1)`:* Rejected because `IPNNotify` messages are sparse delta patches; discarding intermediate updates leaves the client with corrupted, out-of-date state.

---

## Decision 4: Discovery — Automatic Resolution vs. Pinned Configuration

### Problem Statement
When `tailscaled` restarts, its loopback port and local token may change (especially with the standalone macOS app or App Store app). If the client has cached an old port/token, it will fail indefinitely. However, if a caller deliberately configured an explicit endpoint URL or socket path, automatic mutation of that target would violate caller intent.

### Decision
1. **Explicit Configuration Source Tracking**:
   - `TailscaleClientConfiguration` distinguishes automatic discovery from explicitly pinned targets:
     ```swift
     public enum EndpointSource: Sendable, Equatable {
       case automatic(LocalAPIDiscovery)
       case pinned(TailscaleEndpoint)
     }
     ```
2. **Restart Recovery & Credential Re-discovery**:
   - Clients created via `TailscaleClientConfiguration.default` or `LocalAPIDiscovery.discover()` are marked `.automatic`.
   - On repeated connection failures (e.g. ECONNREFUSED) or HTTP 401/403, `.automatic` clients perform single-flight re-discovery to refresh port and token.
   - Pinned configurations (`.pinned`) never perform automatic discovery and report connection failures directly to the caller.
3. **Async Discovery API**:
   - Provide an `async` discovery entry point `LocalAPIDiscovery.discoverAsync()` to avoid blocking the calling actor/thread on filesystem probes or libproc inspection.

### Consumer Sketch
```swift
// Automatic client (recovers credentials on daemon restart):
let client = TailscaleClient()

// Explicitly pinned client (never re-discovers; strictly honors specified target):
let pinnedConfig = TailscaleClientConfiguration(
  endpoint: .unixSocket(path: "/custom/tailscaled.sock"),
  authToken: "secret"
)
let pinnedClient = TailscaleClient(configuration: pinnedConfig)
```

---

## Decision 5: Experimental API Policy

### Problem Statement
Upstream Tailscale frequently introduces experimental endpoints in the LocalAPI. Downstream consumers need clarity on whether experimental Swift methods can break across minor/patch releases.

### Decision
1. **Source Compatibility Guarantee for All Public Symbols**:
   - Every public symbol shipped in the `TailscaleClient` library target is subject to Swift source compatibility under SemVer.
   - We do *not* break public signatures in minor releases, even for methods wrapping upstream experimental endpoints.
2. **Behavioral Tracking vs. API Breaks**:
   - If an upstream daemon changes the payload schema or behavior of an experimental endpoint, `TailscaleClient` tolerates new/omitted fields and documents the daemon version requirement.
   - If upstream completely changes or removes an endpoint: the Swift method will be deprecated or throw a typed `TailscaleClientError.endpointUnavailable`, preserving compilation compatibility.
3. **Independent Versioning Policy**:
   - A separate target in the same Swift package does not provide independent SemVer versioning. If an API is too volatile for 1.0 stability guarantees, it remains internal or ships in a separate experimental package.

---

## Decision 6: Diagnostics Scope (Netcheck / STUN)

### Problem Statement
`Netcheck` performs direct client-side STUN (RFC 8489) UDP probes against DERP/STUN servers to estimate NAT mapping and firewall behavior. It does not speak to the local `tailscaled` daemon. Should it remain in `TailscaleClient` or move to a separate package/product?

### Decision
1. **Retain in Core Product**:
   - Keep `NetcheckClient` in the `TailscaleClient` target for 1.0. It requires no external dependencies (uses standard POSIX UDP / Swift Foundation networking) and is widely used by status and network diagnostic apps (such as NWX).
2. **Explicit Documentation of Scope & Limitations**:
   - Netcheck documentation must clearly state:
     - It is a lightweight client-side RFC 8489 STUN probe.
     - It is *not* a substitute for the full upstream `tailscale netcheck` (which probes captive portals, DERP latency matrices, UPnP, and PMP).
     - Daemon status and connection information should be obtained via `TailscaleClient.status()` or `TailscaleClient.derpMap()`.

---

## Decision 7: Supported Environments and Baseline Matrix

### Problem Statement
`0.12.0` tested against selected tailscaled versions without an explicit numeric support floor or documented OS matrix.

### Decision
1. **Daemon Floor and Compatibility Window**:
   - **Supported Daemon Floor**: `tailscaled` **1.76.0** (released late 2024).
   - **Primary Tested Range**: `1.76.x` through `1.96.x` and latest stable.
   - **Unknown / Absent Features**: Handled gracefully via typed `TailscaleClientError.endpointUnavailable(endpoint:feature:)`.
2. **Platform Matrix**:
   - **macOS**: macOS 13.0+ (Ventura, Sonoma, Sequoia) — full runtime support (Unix socket, standalone `.pkg`, App Store GUI opt-in). Architectures: `arm64`, `x86_64`.
   - **Linux**: Linux kernel 5.4+, `glibc` 2.31+ / `musl` — full runtime support (Unix socket, loopback). Architectures: `x86_64`, `aarch64`.
   - **iOS / tvOS / watchOS**: iOS 16.0+, tvOS 16.0+, watchOS 9.0+ — build-only support for shared models, requests, and mock transports.
3. **Swift Toolchains**:
   - Swift 6.0, 6.1, and 6.2 with strict concurrency (`complete`).
4. **Permissions**:
   - Unprivileged local user for read operations over accessible sockets.
   - Operator permissions (or root) required for daemon mutations depending on daemon configuration (`tailscale set --operator`).

---

## Acceptance and Verification

These decisions are verified by:
1. Committed regression tests in `Tests/TailscaleClientTests/ReadinessRegressionTests.swift`.
2. Consumer sketches compiled against the proposed public signatures.
3. Detailed support matrix documented in [SUPPORT.md](SUPPORT.md).
