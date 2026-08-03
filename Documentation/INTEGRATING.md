# Integrating swift-tailscale-client

**The canonical integration guide** — for humans and AI coding agents alike. The
agent adapters in this repo (`.claude/skills/…`, `AGENTS.md`,
`.github/copilot-instructions.md`, `llms.txt`) all point here; examples live here
once instead of drifting across copies.

`swift-tailscale-client` is an unofficial, MIT-licensed, zero-dependency Swift 6
package that speaks the Tailscale **LocalAPI** — the HTTP API tailscaled serves
over its unix socket / loopback port. It is the Swift analog of Go's
`tailscale.com/client/local`. Not affiliated with Tailscale Inc.

## First: is this the right tool?

| Situation | Correct choice |
|---|---|
| App should observe/control the Tailscale installation the user already has (status, peers, ping, prefs, serve, live state changes) | **This package** |
| App must be its own tailnet node (no Tailscale install; own identity; dial/listen on the tailnet) | `TailscaleKit` from tailscale/libtailscale — NOT this package |
| Managing the tailnet itself (devices, ACLs, auth keys) from a server | `api.tailscale.com` admin REST API — NOT this package |
| Quick shell script on a box with Tailscale | `tailscale` CLI directly |

If Tailscale is not installed on the target machine, this package cannot do
anything — it has no embedded node.

## Add the dependency

```swift
// Package.swift
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.10.0")
// target dependency:
.product(name: "TailscaleClient", package: "swift-tailscale-client")
```

Platforms: macOS 13+ and Linux connect to real daemons (both CI-verified against
live tailscaled); iOS 16+/tvOS 16+/watchOS 9+ are build-verified only — there is
no reachable daemon on those devices. Swift 6 strict concurrency throughout.

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

// Safe writes: only fields you set on MaskedPrefs are touched (v0.8.0+)
var change = MaskedPrefs()
change.shieldsUp = true
let updated = try await client.editPrefs(change)

// Serve/Funnel config with ETag optimistic concurrency (v0.10.0+):
// snapshot -> mutate -> write; a concurrent change throws .preconditionFailed.
var serve = try await client.serveConfig()
serve.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
try await client.setServeConfig(serve)
let certs  = try await client.certDomains()         // tailnet TLS domains (v0.10.0+)

// Real-time updates (preferred over polling)
for try await notify in try await client.watchIPNBus(options: [.initialState, .initialHealthState]) {
    if let state = notify.state { /* .running, .stopped, .needsLogin ... */ }
    if let health = notify.health { /* warnings dictionary */ }
}
```

All calls throw `TailscaleClientError` (`.transport`,
`.unexpectedStatus(code:body:endpoint:)`, `.decoding`, `.endpointUnavailable`,
`.timeout`, `.preconditionFailed`, `.permissionDenied`, `.rateLimited`,
`.peerNotFound`) with actionable `recoverySuggestion`s. For audited
operations (e.g. always-on mode), scope a justification with
`TailscaleClient.withAuditReason("ticket…") { … }` — it is task-local, so
concurrent operations never inherit each other's reasons;
`versionDiagnostics()` reports the package version, advertised capability,
and observed daemon version for bug reports. These guarantees — typed status
mapping, audit-reason injection, and daemon-version observation — apply to
**unary** requests only: streaming connections (`watchIPNBus`,
`experimental.logtap`) surface connection failures as `.transport` without
the typed status mapping.

## Critical integration gotchas

1. **macOS App Store Tailscale requires opt-in discovery and triggers a TCC
   popup.** Default discovery uses unix sockets only (Homebrew
   `/var/run/tailscaled.socket`, system daemon paths) — no popups. If users run
   the App Store GUI app, you must explicitly use
   `TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)` and
   expect a "wants to access data from other apps" permission prompt. Explain it
   to users first.
2. **Sandboxed apps** need the right entitlements to reach the unix socket /
   Group Containers; test discovery in the sandbox early.
3. **The LocalAPI is not formally stable** (upstream namespaces it
   `/localapi/v0/` deliberately) and endpoint availability varies with the
   daemon's version *and* build features. Version- or build-gated endpoints
   throw `.endpointUnavailable` — the quick reference below marks every caveat.
   Probe `daemonFeatures()` when you need to know up front.
4. **Streaming (v0.4.0+):** malformed lines are skipped (observe via the
   `onUndecodableLine:` callback), and long-lived monitors should pass
   `reconnect: .default` for automatic re-dial with backoff.
5. **Writes are replace-or-patch, know which:** `editPrefs(_:)` patches only the
   `MaskedPrefs` fields you set; `setServeConfig(_:)` **replaces the whole serve
   config** — always start from a fresh `serveConfig()` snapshot, and retry on
   `.preconditionFailed` (someone else wrote concurrently).
6. **Environment overrides** for testing/CI: `TAILSCALE_LOCALAPI_SOCKET`,
   `TAILSCALE_LOCALAPI_PORT`/`_HOST`, `TAILSCALE_LOCALAPI_URL`,
   `TAILSCALE_DISCOVERY_DEBUG=1` (logs discovery to stderr).

## Endpoint quick reference

Generated from [`Documentation/endpoints.json`](endpoints.json) — the
machine-readable manifest (endpoint, symbol, read/write risk, feature gate,
minimum/tested tailscaled versions, transports, and **two independent
stability axes**: Tailscale's own upstream "API maturity" annotation and this
package's Swift-support promise; "supported" over an upstream-unstable
endpoint means we normalize drift, not that Tailscale guarantees the wire).
Consume the JSON directly if you're an agent; CI fails when this table
drifts from it.

<!-- BEGIN GENERATED: endpoint-quick-reference (Scripts/generate-endpoint-docs.py) -->
| Swift API | Endpoint | Access | Stability & availability |
|---|---|---|---|
| `status(query:)` | `status` | read | upstream stable; supported Swift API |
| `whois(address:), whois(address:protocol:), whois(nodeKey:), whois(address:scopedToDestination:), whois(address:forService:)` | `whois` | read | upstream stable; supported Swift API |
| `prefs(), editPrefs(_:)` | `prefs` | write | upstream stable; supported Swift API |
| `ping(ip:type:size:)` | `ping` | read | no upstream maturity note (assume unstable); supported Swift normalization layer |
| `metrics()` | `metrics` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; absent on builds without `HasClientMetrics` |
| `userMetrics()` | `usermetrics` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled 1.78 |
| `watchIPNBus(options:reconnect:onUndecodableLine:)` | `watch-ipn-bus` | read | upstream unstable; supported Swift normalization layer |
| `daemonFeatures()` | `debug-optional-features` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled 1.86 |
| `derpMap()` | `derpmap` | read | upstream stable; supported Swift API |
| `suggestExitNode(forceProbe:)` | `suggest-exit-node` | read | no upstream maturity note (assume unstable); supported Swift normalization layer |
| `dnsOSConfig()` | `dns-osconfig` | read | upstream unstable; supported Swift normalization layer |
| `dnsQuery(name:type:)` | `dns-query` | read | no upstream maturity note (assume unstable); supported Swift normalization layer |
| `checkIPForwarding()` | `check-ip-forwarding` | read | upstream unstable; supported Swift normalization layer |
| `checkUDPGROForwarding()` | `check-udp-gro-forwarding` | read | upstream unstable; supported Swift normalization layer |
| `dnsConfig()` | `dns-config` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled 1.98 |
| `peer(byID:)` | `peer-by-id` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled ~1.98 |
| `userProfile(byID:)` | `user-profile` | read | upstream stable; supported Swift API; needs tailscaled ~1.98 |
| `checkPrefs(_:)` | `check-prefs` | read | no upstream maturity note (assume unstable); supported Swift normalization layer |
| `setUseExitNode(enabled:)` | `set-use-exit-node-enabled` | write | upstream stable; supported Swift API |
| `setExpirySooner(_:)` | `set-expiry-sooner` | write | upstream unstable; supported Swift normalization layer |
| `reloadConfig()` | `reload-config` | write | no upstream maturity note (assume unstable); supported Swift normalization layer |
| `start(options:)` | `start` | write | no upstream maturity note (assume unstable); supported Swift normalization layer |
| `loginInteractive()` | `login-interactive` | write | upstream stable; supported Swift API |
| `logout()` | `logout` | destructive | **destructive**; no upstream maturity note (assume unstable); supported Swift normalization layer |
| `checkUpdate()` | `update/check` | read | upstream stable; supported Swift API |
| `disconnectControl()` | `disconnect-control` | write | upstream stable; supported Swift API |
| `resetAuth()` | `reset-auth` | destructive | **destructive**; no upstream maturity note (assume unstable); supported Swift normalization layer |
| `profiles(), currentProfile(), addProfile(), switchProfile(_:), deleteProfile(_:)` | `profiles/` | write | no upstream maturity note (assume unstable) (per-symbol exceptions in the coverage matrix); supported Swift normalization layer |
| `idToken(audience:)` | `id-token` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; absent on builds without `HasDebug` |
| `serveConfig(), setServeConfig(_:)` | `serve-config` | write | upstream unstable (per-symbol exceptions in the coverage matrix); supported Swift normalization layer; absent on builds without `HasServe` |
| `certDomains()` | `cert-domains` | read | upstream stable; supported Swift API; absent on builds without `HasACME` |
| `certPEM(domain:kind:minValidity:), certPair(domain:minValidity:)` | `cert/` | read | upstream stable; supported Swift API; absent on builds without `HasACME` |
| `setDNS(name:value:)` | `set-dns` | write | no upstream maturity note (assume unstable); supported Swift normalization layer; absent on builds without `HasACME` |
| `queryFeature(_:)` | `query-feature` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; absent on builds without `HasServe` |
| `bugReport(note:) (supported), experimental.bugreport(note:diagnose:record:)` | `bugreport` | write | upstream stable; supported Swift API; absent on builds without `HasDebug` |
| `experimental.goroutines()` | `goroutines` | read | no upstream maturity note (assume unstable); experimental Swift API (SemVer-exempt); absent on builds without `HasDebug` |
| `experimental.logtap()` | `logtap` | read | upstream unstable; experimental Swift API (SemVer-exempt); absent on builds without `HasDebug` |
| `experimental.setGUIVisible(_:sessionID:)` | `set-gui-visible` | write | no upstream maturity note (assume unstable); experimental Swift API (SemVer-exempt) |
| `experimental.setPushDeviceToken(_:)` | `set-push-device-token` | write | no upstream maturity note (assume unstable); experimental Swift API (SemVer-exempt) |
| `experimental.handlePushMessage(_:)` | `handle-push-message` | write | no upstream maturity note (assume unstable); experimental Swift API (SemVer-exempt) |
<!-- END GENERATED: endpoint-quick-reference (Scripts/generate-endpoint-docs.py) -->

## Testing an app that uses this package

Use the shipped `TailscaleClientMocks` product (v0.4.0+) — add it as a
test-target dependency:

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

`RequestRecorder` (an actor) captures requests for assertions. On older
versions, conform your own stub to the public `TailscaleTransport` protocol
instead.

## Repo map (for contributors)

- `Sources/TailscaleClient/` — library: `TailscaleClient.swift` (actor +
  errors), `Configuration/` (discovery), `Transport/` (URLSession + unix
  socket), `Models/`, `Netcheck/`, `Platform/` (macOS discovery, interface
  detection)
- `Sources/tailscale-swift/` — CLI executable product; every structured command
  takes `--json`
- `ROADMAP.md` — version plan and stability tiers;
  [`LOCALAPI-COVERAGE.md`](LOCALAPI-COVERAGE.md) — the position on every
  LocalAPI endpoint; [`TESTING.md`](TESTING.md) — spike-first workflow and
  harness; `CLAUDE.md` — build/test commands and architecture conventions
