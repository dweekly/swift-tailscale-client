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
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.6.0")
// target dependency:
.product(name: "TailscaleClient", package: "swift-tailscale-client")
```

Platforms: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, Linux (v0.5.0+, unix-socket endpoints;
interface discovery and loopback streaming stay Darwin-only). Swift 6 strict concurrency.

## Core usage patterns

```swift
import TailscaleClient

let client = TailscaleClient()  // auto-discovers the LocalAPI (unix socket first)

// One-shot queries
let status = try await client.status()              // nodes, peers, health, backendState
let whois  = try await client.whois(address: "100.64.0.5")
let prefs  = try await client.prefs()               // exit node, shields, routes...
let ping   = try await client.ping(ip: "100.64.0.5")
let text   = try await client.metrics()             // internal Prometheus counters
let user   = try await client.userMetrics()         // stable user metrics (v0.6.0+)
let derp   = try await client.derpMap()             // DERP relay regions/nodes (v0.6.0+)
let exit   = try await client.suggestExitNode()     // recommended exit node (v0.6.0+)
let net    = try await client.netcheck()            // client-side STUN probe: region latency,
                                                    // public IP, NAT hardness (v0.6.0+)
let dns    = try await client.dnsOSConfig()         // OS DNS config (v0.7.0+)
let ans    = try await client.dnsQuery(name: "peer.ts.net")  // MagicDNS-path query (v0.7.0+)
let node   = try await client.peer(byID: whois.node!.id)     // numeric-ID lookups (v0.7.0+)
// client.experimental.{bugreport,goroutines,logtap} — SemVer-exempt debug tier (v0.7.0+)

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
4. **Streaming (v0.4.0+):** malformed lines are skipped (observe via the `onUndecodableLine:`
   callback), and long-lived monitors should pass `reconnect: .default` for automatic re-dial
   with backoff. All watch options including `initialPrefs`/`initialNetMap` are decodable.
   On v0.3.1 and earlier, a malformed line kills the stream — wrap in a retry loop there.
5. **Environment overrides** for testing/CI: `TAILSCALE_LOCALAPI_SOCKET`, `TAILSCALE_LOCALAPI_PORT`/
   `_HOST`, `TAILSCALE_LOCALAPI_URL`, `TAILSCALE_DISCOVERY_DEBUG=1` (logs discovery to stderr).

## Testing an app that uses this package

Use the shipped `TailscaleClientMocks` product (v0.4.0+) — add it as a test-target dependency:

```swift
import TailscaleClientMocks

let transport = MockTransport { request, _ in
    TailscaleResponse(statusCode: 200, data: fixtureJSON)
}
// Streaming: MockTransport.scriptedStream([.jsonLine("{\"State\":6}"), .delay(.seconds(1))])
// Reconnect scenarios: MockTransport.scriptedStreams([[...first connection...], [...second...]])
let config = TailscaleClientConfiguration(
    endpoint: .url(URL(string: "http://mock.local")!), authToken: nil, transport: transport)
let client = TailscaleClient(configuration: config)
```

`RequestRecorder` (an actor) captures requests for assertions. On older versions, conform your
own stub to the public `TailscaleTransport` protocol instead.

## Repo map (for contributors)

- `Sources/TailscaleClient/` — library: `TailscaleClient.swift` (actor + errors), `Configuration/`
  (discovery), `Transport/` (URLSession + unix socket), `Models/`, `Platform/` (macOS discovery,
  interface detection)
- `Sources/tailscale-swift/` — CLI executable product (`status`, `whois`, `prefs`, `ping`, `health`,
  `metrics`, `usermetrics`, `watch`, `features`, `derpmap`, `suggest-exit`, `netcheck`, `dns`,
  `check-forwarding`; `--json` on structured commands)
- `ROADMAP.md` — version plan and stability tiers; `Documentation/LOCALAPI-COVERAGE.md` — status of
  every LocalAPI endpoint; `Documentation/TESTING.md` — spike-first workflow and harness;
  `CLAUDE.md` — build/test commands and architecture conventions
