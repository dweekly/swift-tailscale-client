# Integrating swift-tailscale-client

**The canonical integration guide** — for humans and AI coding agents alike. The
agent adapters in this repo (`.claude/skills/…`, `AGENTS.md`,
`.github/copilot-instructions.md`, `llms.txt`) all point here; examples live here
once instead of drifting across copies.

`swift-tailscale-client` is an unofficial, MIT-licensed Swift 6 package that
speaks the Tailscale **LocalAPI** — the HTTP API tailscaled serves
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

Requires Swift 6.1 or later (`swift-tools-version: 6.1` in `Package.swift`).

```swift
// Package.swift
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "1.1.0")
// app target dependency:
.product(name: "TailscaleClient", package: "swift-tailscale-client")
// test target dependencies (see "Testing an app that uses this package"):
dependencies: [
    .product(name: "TailscaleClient", package: "swift-tailscale-client"),
    .product(name: "TailscaleClientMocks", package: "swift-tailscale-client"),
]
```

`PingResult.path`, `PingPath`, and the watch options `.peerChanges`,
`.noNetMap`, `.initialStatus`, and `.peerPatches` are 1.1.0 additions.

The `TailscaleClient` and `TailscaleClientMocks` libraries have no
third-party dependencies. Resolving the package also fetches
swift-argument-parser, which the `tailscale-swift` CLI product uses, so it
appears in your `Package.resolved`.

Release platforms: macOS 13+ connects to installed daemons; iOS 16+/tvOS 16+/watchOS 9+
are build-verified only — there is no reachable daemon on those devices. Linux
is unqualified: it is not built or tested in required CI. Swift 6 strict
concurrency throughout.

## Upgrading from 1.0

Change the pin to `from: "1.1.0"`. Code written against 1.0 compiles unchanged:
the public API baseline from `v1.0.0` is intact, with no allowed breaks. Check
code that depends on these behavior changes:

- **`PingResult.isDirect`** is `true` only when a disco ping took a direct path.
  In 1.0 it was also `true` for TSMP, ICMP, peerAPI and failed pings. Read
  `PingResult.path` to see how a reply traveled.
- **Watches on Tailscale 1.104 and later.** Those daemons reject
  `.initialNetMap` and `.rateLimit` (both part of `NotifyWatchOpt.default`).
  The client retries without them, so the watch opens, but no `NetMap` arrives.
  Code that reads peers from `IPNNotify.netMap` gets nothing there. Subscribe
  with `[.initialState, .peerChanges, .noNetMap]` and re-read `status()` on
  each notification instead (gotcha 4 and the Peer Diagnostics sample).
- **Fixes with no action needed:** `PingType.peerAPI` pings get an answer; a
  rejected watch throws its status error at once instead of hanging; loopback
  watches (the standalone and App Store apps) stay open through quiet periods
  and, with a reconnect policy, follow a daemon that restarts on a new port.

[`CHANGELOG.md`](../CHANGELOG.md#110---2026-11-21) lists every change.

## Start with the sample app

The sample needs a checkout of this repository, on macOS 13+ with Swift 6.1+:

```bash
git clone https://github.com/dweekly/swift-tailscale-client.git
cd swift-tailscale-client
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics             # window
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics --fixture --print  # headless
```

[`Examples/PeerDiagnostics`](../Examples/PeerDiagnostics) lists peers and shows how
a ping reached the selected one. Copy its patterns:

- **Fixture versus live.** It starts in fixture mode: a built-in, made-up
  tailnet behind the same `DaemonConnection` protocol as the real daemon, so it
  runs and tests with no Tailscale installed. Live mode is an explicit switch
  (the window's **Live** control, or `--live`) and is read-only: `status()`,
  disco `ping(ip:type:)` to the selected peer, and one IPN bus watch.
- **Discovery consent.** Finding the Mac App Store edition is a separate,
  default-off toggle that warns about the macOS permission prompt before it is
  used (gotcha 1 below).
- **Reading a ping.** It classifies each reply with `PingResult.path`, sends a
  bounded burst (up to 5 pings, 1 s apart, 5 s timeout each, stopping at the
  first `.direct`), calls only a direct ending the settled path, labels any
  other last reply as one measurement, and shows each result's time and
  staleness (gotcha 7 below).
- **Keeping peers current.** It re-reads `status()` on every notification,
  reconnect, and state gap (gotcha 4 below).

The DocC article `RecipePeerDiagnostics` quotes the compiled code for each
pattern, and the sample's README explains every label in the window.

## Core usage patterns

```swift
import TailscaleClient

let client = TailscaleClient()  // auto-discovers the LocalAPI (unix socket first)

// One-shot queries
let status = try await client.status()              // nodes, peers, health, backendState
let whois  = try await client.whois(address: "100.64.0.5")
let prefs  = try await client.prefs()               // exit node, shields, routes...
let ping   = try await client.ping(ip: "100.64.0.5")  // type defaults to .disco; ping.path (1.1.0+): .direct/.peerRelay/.derp/.unknown, nil on error
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
let snapshot = try await client.serveConfigSnapshot()
var serve = snapshot.config
serve.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
_ = try await client.setServeConfig(serve, matching: snapshot)
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
and observed daemon version for bug reports. In 1.0, both unary and streaming
connections (`watchIPNBusEvents`) validate the HTTP response head metadata
before yielding events, ensuring typed error mapping (such as `.permissionDenied`
or `.endpointUnavailable`) even on streaming endpoints.

## Critical integration gotchas

1. **macOS App Store Tailscale requires opt-in discovery and triggers a TCC
   popup.** Default discovery checks environment overrides, unix sockets
   (Homebrew `/var/run/tailscaled.socket`, system daemon paths), and the
   standalone `.pkg` app's loopback port (`/Library/Tailscale/ipnport`) — no
   popups. If users run
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
   **Watch options on Tailscale 1.104+:** those daemons reject `.initialNetMap`
   and `.rateLimit` with HTTP 400 and no longer send `IPNNotify.netMap`. The
   client reopens the watch once without those two options and omits them on
   later watches from the same client, so `.default` and `.allInitial` keep
   working; a daemon that accepts them gets exactly your mask. To follow peers
   on every daemon version, subscribe with
   `[.initialState, .peerChanges, .noNetMap]` and re-read `status()` on each
   notification and reconnect (`IPNNotify` does not model the peer-delta or
   `InitialStatus` fields yet; such notifications still decode). Any other 400
   is fatal: it fails the initial open and ends a reconnecting stream instead of
   being retried.
5. **Writes are replace-or-patch, know which:** `editPrefs(_:)` patches only the
   `MaskedPrefs` fields you set; `setServeConfig(_:matching:)` **replaces the whole serve
   config** — always start from a fresh `serveConfigSnapshot()` snapshot, and retry on
   `.preconditionFailed` (someone else wrote concurrently).
6. **Environment overrides** for testing/CI: `TAILSCALE_LOCALAPI_SOCKET`,
   `TAILSCALE_LOCALAPI_PORT`/`_HOST`, `TAILSCALE_LOCALAPI_URL`,
   `TAILSCALE_DISCOVERY_DEBUG=1` (logs discovery to stderr). A Unix socket
   path must fit the platform's limit (about 104 bytes on macOS); a longer
   `TAILSCALE_LOCALAPI_SOCKET` fails with "File name too long".
7. **Read a ping's path from `PingResult.path` (1.1.0+), not the raw fields.**
   The daemon always sends `Endpoint`, `PeerRelay`, `DERPRegionID`, and `Err`,
   using `""` and `0` for "none", so `endpoint != nil` says nothing. `path` is
   `nil` when `error` is nonempty, otherwise the first of `.peerRelay(endpoint:)`,
   `.derp(regionID:regionCode:)`, `.direct(endpoint:)` (the precedence
   `tailscale ping` uses), else `.unknown`. Only `.disco` pings report a path;
   `.tsmp`, `.icmp`, and `.peerAPI` replies are always `.unknown`. One reply is
   one measurement: the first disco ping to an idle peer is often DERP while a
   direct path forms, which is why `tailscale ping` repeats until direct. Do not
   present a single `.derp` reply as the peer's settled path. `isDirect` is
   `true` exactly when `path` is `.direct`. The other fields a caller needs are
   `latencySeconds: Double?` and `error: String?` (nil or empty means the ping
   succeeded); the DERP case is `.derp(regionID: Int, regionCode: String?)`.
   `ping(ip:type:size:)` defaults to `type: .disco`. It **returns normally when
   the daemon reports a failed ping** (check `path == nil` or `error`) and
   throws only for transport, HTTP-status, decoding, or request-timeout failures. To test each
   case without a daemon, see the ping example under "Testing an app that uses
   this package".

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
| `status(query:)` | `status` | read | upstream stable; supported Swift API; observed live on tailscaled 1.102.2 (read) |
| `services()` | `services` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled recent (VIP services era; older daemons -> endpointUnavailable); observed live on tailscaled 1.102.2 (read) |
| `whois(address:), whois(address:protocol:), whois(nodeKey:), whois(address:scopedToDestination:), whois(address:forService:)` | `whois` | read | upstream stable; supported Swift API; observed live on tailscaled 1.102.2 (read) |
| `prefs(), editPrefs(_:)` | `prefs` | write | upstream stable; supported Swift API; observed live on tailscaled 1.102.2 (read) |
| `ping(ip:type:size:)` | `ping` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; observed live on tailscaled 1.102.2 (read) |
| `metrics()` | `metrics` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasClientMetrics || HasDebug` |
| `userMetrics()` | `usermetrics` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled 1.78; observed live on tailscaled 1.102.2 (read); absent on builds without `HasUserMetrics` |
| `watchIPNBus(options:reconnect:onUndecodableLine:), watchIPNBusEvents(options:retryPolicy:bounds:onUndecodableLine:)` | `watch-ipn-bus` | read | upstream unstable; supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasIPNBus` |
| `daemonFeatures()` | `debug-optional-features` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled 1.86; observed live on tailscaled 1.102.2 (read); absent on builds without `HasDebug` |
| `derpMap()` | `derpmap` | read | upstream stable; supported Swift API; observed live on tailscaled 1.102.2 (read) |
| `suggestExitNode(forceProbe:)` | `suggest-exit-node` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasUseExitNode` |
| `dnsOSConfig()` | `dns-osconfig` | read | upstream unstable; supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasDNS` |
| `dnsQuery(name:type:)` | `dns-query` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasDNS` |
| `checkIPForwarding()` | `check-ip-forwarding` | read | upstream unstable; supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasAdvertiseRoutes` |
| `checkUDPGROForwarding()` | `check-udp-gro-forwarding` | read | upstream unstable; supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasAdvertiseRoutes` |
| `dnsConfig()` | `dns-config` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled 1.98; observed live on tailscaled 1.102.2 (read) |
| `peer(byID:)` | `peer-by-id` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; needs tailscaled ~1.98; observed live on tailscaled 1.102.2 (read) |
| `userProfile(byID:)` | `user-profile` | read | upstream stable; supported Swift API; needs tailscaled ~1.98; not yet observed on a live daemon by 1.x tests |
| `checkPrefs(_:)` | `check-prefs` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; not yet observed on a live daemon by 1.x tests |
| `setUseExitNode(enabled:)` | `set-use-exit-node-enabled` | write | upstream stable; supported Swift API; not yet observed on a live daemon by 1.x tests; absent on builds without `HasUseExitNode` |
| `setExpirySooner(_:)` | `set-expiry-sooner` | write | upstream unstable; supported Swift normalization layer; not yet observed on a live daemon by 1.x tests |
| `reloadConfig()` | `reload-config` | write | no upstream maturity note (assume unstable); supported Swift normalization layer; not yet observed on a live daemon by 1.x tests |
| `start(options:) / startFreshProfile(controlURL:authKey:)` | `start` | write | no upstream maturity note (assume unstable); supported Swift normalization layer; not yet observed on a live daemon by 1.x tests |
| `loginInteractive()` | `login-interactive` | write | upstream stable; supported Swift API; not yet observed on a live daemon by 1.x tests |
| `logout()` | `logout` | destructive | **destructive**; no upstream maturity note (assume unstable); supported Swift normalization layer; not yet observed on a live daemon by 1.x tests |
| `shutdownTailscaled()` | `shutdown` | destructive | **destructive**; upstream unstable; supported Swift normalization layer; needs tailscaled recent (older daemons -> endpointUnavailable); not yet observed on a live daemon by 1.x tests |
| `checkUpdate()` | `update/check` | read | upstream stable; supported Swift API; observed live on tailscaled 1.102.2 (read); absent on builds without `HasClientUpdate` |
| `disconnectControl()` | `disconnect-control` | write | upstream stable; supported Swift API; not yet observed on a live daemon by 1.x tests; absent on builds without `HasDebug || HasAdvertiseRoutes` |
| `resetAuth()` | `reset-auth` | destructive | **destructive**; no upstream maturity note (assume unstable); supported Swift normalization layer; not yet observed on a live daemon by 1.x tests |
| `profiles(), currentProfile(), switchToEmptyProfile(), switchProfile(_:), deleteProfile(_:)` | `profiles/` | write | no upstream maturity note (assume unstable) (per-symbol exceptions in the coverage matrix); supported Swift normalization layer; observed live on tailscaled 1.102.2 (read) |
| `idToken(audience:)` | `id-token` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; not yet observed on a live daemon by 1.x tests; absent on builds without `HasDebug` |
| `serveConfigSnapshot(), setServeConfig(_:matching:), replaceServeConfigUnconditionally(_:)` | `serve-config` | write | upstream unstable (per-symbol exceptions in the coverage matrix); supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasServe` |
| `certDomains()` | `cert-domains` | read | upstream stable; supported Swift API; observed live on tailscaled 1.102.2 (read) |
| `certPEM(domain:kind:minValidity:), certPair(domain:minValidity:)` | `cert/` | read | upstream stable; supported Swift API; not yet observed on a live daemon by 1.x tests; absent on builds without `HasACME` |
| `setDNS(name:value:)` | `set-dns` | write | no upstream maturity note (assume unstable); supported Swift normalization layer; not yet observed on a live daemon by 1.x tests; absent on builds without `HasACME` |
| `queryFeature(_:)` | `query-feature` | read | no upstream maturity note (assume unstable); supported Swift normalization layer; observed live on tailscaled 1.102.2 (read); absent on builds without `HasServe` |
| `bugReport(note:) (supported), experimental.bugreport(note:diagnose:record:)` | `bugreport` | write | upstream stable; supported Swift API; not yet observed on a live daemon by 1.x tests; absent on builds without `HasDebug` |
| `experimental.goroutines()` | `goroutines` | read | no upstream maturity note (assume unstable); experimental Swift API (SemVer-exempt); observed live on tailscaled 1.102.2 (read) |
| `experimental.logtap()` | `logtap` | read | upstream unstable; experimental Swift API (SemVer-exempt); not yet observed on a live daemon by 1.x tests; absent on builds without `HasLogTail` |
| `experimental.setGUIVisible(_:sessionID:)` | `set-gui-visible` | write | no upstream maturity note (assume unstable); experimental Swift API (SemVer-exempt); not yet observed on a live daemon by 1.x tests; absent on builds without `HasDebug || windows || darwin` |
| `experimental.setPushDeviceToken(_:)` | `set-push-device-token` | write | no upstream maturity note (assume unstable); experimental Swift API (SemVer-exempt); not yet observed on a live daemon by 1.x tests; absent on builds without `HasDebug` |
| `experimental.handlePushMessage(_:)` | `handle-push-message` | write | no upstream maturity note (assume unstable); experimental Swift API (SemVer-exempt); not yet observed on a live daemon by 1.x tests; absent on builds without `HasDebug` |
<!-- END GENERATED: endpoint-quick-reference (Scripts/generate-endpoint-docs.py) -->

## Testing an app that uses this package

Use the shipped `TailscaleClientMocks` product (v0.4.0+) — add it as a
test-target dependency:

```swift
import TailscaleClientMocks

// fixtureJSON is the response body as Data. The closure receives the request
// and the client's TailscaleClientConfiguration; return a TailscaleResponse.
let transport = MockTransport { request, configuration in
    TailscaleResponse(statusCode: 200, data: fixtureJSON)
}
// Streaming: MockTransport.scriptedStream([.jsonLine("{\"State\":6}"), .delay(.seconds(1))])
// Reconnect scenarios: MockTransport.scriptedStreams([[...first connection...], [...second...]])
let config = TailscaleClientConfiguration(
    endpoint: .url(URL(string: "http://mock.local")!), authToken: nil, transport: transport)
let client = TailscaleClient(configuration: config)
```

**Ping replies.** The mock returns the daemon's JSON, not a `PingResult`. A
disco reply always carries these fields, with `""` and `0` meaning "none":

```json
{"IP":"100.64.0.5","NodeIP":"100.64.0.5","NodeName":"example-peer","Err":"","LatencySeconds":0.005,"Endpoint":"","PeerRelay":"","DERPRegionID":0,"DERPRegionCode":""}
```

Set `Endpoint` (for example `"192.0.2.10:41641"`) for `.direct`,
`DERPRegionID` and `DERPRegionCode` for `.derp`, `PeerRelay` for
`.peerRelay`, and `Err` for a failed ping (`path == nil`); leave them all
empty for `.unknown`. The compiled versions are
[`Examples/Recipes/Sources/Recipes/PingPath.swift`](../Examples/Recipes/Sources/Recipes/PingPath.swift)
and `testPingWithNoPathIsUnknown` in
[`MockedClientTests.swift`](../Examples/Recipes/Tests/RecipesTests/MockedClientTests.swift).

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
