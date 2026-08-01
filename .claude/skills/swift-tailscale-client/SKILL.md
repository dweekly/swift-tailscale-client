---
name: swift-tailscale-client
description: >
  Integrate or use swift-tailscale-client, the unofficial Swift 6 async/await client for the
  Tailscale LocalAPI. Use when adding Tailscale status, peer, ping, preferences, or real-time
  state-change monitoring to a Swift app that talks to an ALREADY-INSTALLED Tailscale daemon
  (tailscaled). Also use to decide between this package and alternatives (TailscaleKit/tsnet
  embedding, the tailscale CLI, or the api.tailscale.com admin API).
---

# swift-tailscale-client integration guide

Unofficial, MIT-licensed, zero-dependency Swift 6 package (`TailscaleClient` library) that speaks the
Tailscale **LocalAPI** — the HTTP API tailscaled serves over its unix socket / loopback port. It is the
Swift analog of Go's `tailscale.com/client/local`. Not affiliated with Tailscale Inc.

## First: is this the right tool?

| Situation | Correct choice |
|---|---|
| App should observe/control the Tailscale installation the user already has (status, peers, ping, prefs, live state changes) | **This package** |
| App must be its own tailnet node (no Tailscale install; own identity; dial/listen on the tailnet) | `TailscaleKit` from tailscale/libtailscale — NOT this package |
| Managing the tailnet itself (devices, ACLs, auth keys) from a server | `api.tailscale.com` admin REST API — NOT this package |
| Quick shell script on a box with Tailscale | `tailscale` CLI directly |

If Tailscale is not installed on the target machine, this package cannot do anything — it has no
embedded node.

## Add the dependency

```swift
// Package.swift
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.3.1")
// target dependency:
.product(name: "TailscaleClient", package: "swift-tailscale-client")
```

Platforms: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+. Swift 6 strict concurrency; all types Sendable.
Linux support is on the roadmap (transport currently throws `.unimplemented` there).

## Core usage patterns

```swift
import TailscaleClient

let client = TailscaleClient()  // auto-discovers the LocalAPI (unix socket first)

// One-shot queries
let status = try await client.status()              // nodes, peers, health, backendState
let whois  = try await client.whois(address: "100.64.0.5")
let prefs  = try await client.prefs()               // exit node, shields, routes...
let ping   = try await client.ping(ip: "100.64.0.5")
let text   = try await client.metrics()             // Prometheus exposition format

// Real-time updates (preferred over polling)
for try await notify in try await client.watchIPNBus(options: [.initialState, .initialHealthState]) {
    if let state = notify.state { /* .running, .stopped, .needsLogin ... */ }
    if let health = notify.health { /* warnings dictionary */ }
}
```

All calls throw `TailscaleClientError` (`.transport`, `.unexpectedStatus(code:body:endpoint:)`,
`.decoding`) with actionable `recoverySuggestion`s.

## Critical integration gotchas

1. **macOS App Store Tailscale requires opt-in discovery and triggers a TCC popup.** Default
   discovery uses unix sockets only (Homebrew `/var/run/tailscaled.socket`, system daemon paths) —
   no popups. If users run the App Store GUI app, you must explicitly use
   `TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)` and expect a
   "wants to access data from other apps" permission prompt. Explain it to users first.
2. **Sandboxed apps** need the right entitlements to reach the unix socket / Group Containers;
   test discovery in the sandbox early.
3. **The LocalAPI is not formally stable** (upstream namespaces it `/localapi/v0/` deliberately) and
   endpoint availability varies with how tailscaled was built. Handle
   `.unexpectedStatus(404, ...)` on optional endpoints gracefully. Check
   `Documentation/LOCALAPI-COVERAGE.md` for each endpoint's status and tier.
4. **Streaming caveat (v0.3.1):** a malformed line terminates the `watchIPNBus` stream — wrap
   consumption in a retry loop for long-lived monitors (built-in skip+reconnect is planned v0.4.0).
   Don't request `initialPrefs`/`initialNetMap` watch options yet; their payloads aren't modeled.
5. **Environment overrides** for testing/CI: `TAILSCALE_LOCALAPI_SOCKET`, `TAILSCALE_LOCALAPI_PORT`/
   `_HOST`, `TAILSCALE_LOCALAPI_URL`, `TAILSCALE_DISCOVERY_DEBUG=1` (logs discovery to stderr).

## Testing an app that uses this package

Inject a mock transport — `TailscaleTransport` is a public protocol:

```swift
struct StubTransport: TailscaleTransport {
    func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration) async throws -> TailscaleResponse {
        TailscaleResponse(statusCode: 200, headers: [:], body: fixtureJSON)
    }
    func sendStreaming(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration) async throws -> AsyncThrowingStream<Data, Error> { ... }
}
let config = TailscaleClientConfiguration(endpoint: .unixSocket(path: "/dev/null"), transport: StubTransport())
let client = TailscaleClient(configuration: config)
```

(A shipped `TailscaleClientMocks` product with scripted transports is planned for v0.4.0.)

## Repo map (for contributors)

- `Sources/TailscaleClient/` — library: `TailscaleClient.swift` (actor + errors), `Configuration/`
  (discovery), `Transport/` (URLSession + unix socket), `Models/`, `Platform/` (macOS discovery,
  interface detection)
- `Sources/tailscale-swift/` — dev CLI (`status`, `whois`, `prefs`, `ping`, `health`, `metrics`, `watch`)
- `ROADMAP.md` — version plan and stability tiers; `Documentation/LOCALAPI-COVERAGE.md` — status of
  every LocalAPI endpoint; `Documentation/TESTING.md` — spike-first workflow and harness;
  `CLAUDE.md` — build/test commands and architecture conventions
