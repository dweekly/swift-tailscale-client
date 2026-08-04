# swift-tailscale-client

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdweekly%2Fswift-tailscale-client%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/dweekly/swift-tailscale-client)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdweekly%2Fswift-tailscale-client%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/dweekly/swift-tailscale-client)
[![License MIT](https://img.shields.io/github/license/dweekly/swift-tailscale-client)](LICENSE)
[![CI](https://github.com/dweekly/swift-tailscale-client/workflows/CI/badge.svg)](https://github.com/dweekly/swift-tailscale-client/actions)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blue)](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/)

> Swift SDK for the Tailscale LocalAPI — control an existing tailscaled daemon with async/await

`swift-tailscale-client` is a personal, MIT-licensed project by David E. Weekly. It is **not** an official Tailscale product and is not endorsed by Tailscale Inc. The goal is to provide an idiomatic async/await Swift interface to the LocalAPI so Apple-platform and Linux apps can query and control Tailscale state without shelling out to the `tailscale` CLI.

API documentation is published to [GitHub Pages](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/) on every push to `main`, and the [Swift Package Index](https://swiftpackageindex.com/dweekly/swift-tailscale-client) builds a versioned mirror from `.spi.yml` — see [its documentation tab](https://swiftpackageindex.com/dweekly/swift-tailscale-client/documentation) for per-release docs.

## What This Package Does

This package **connects to an existing tailscaled daemon** to query its state and configuration. It's designed for building monitoring tools, status widgets, dashboards, and developer utilities that work with an existing Tailscale installation.

**This is NOT an embedded Tailscale implementation.** If you need to embed Tailscale directly into your application (making your app its own tailnet node), see Tailscale's official [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift) instead.

## Choosing the Right Tool

There are several ways to work with Tailscale from Swift (or from anywhere). Pick by what you're building:

| You want to… | Use | Why |
|---|---|---|
| Show/monitor/control the **Tailscale installation the user already has** (menu bar apps, widgets, dashboards, diagnostics) | **swift-tailscale-client** (this package) | Talks to the local daemon's LocalAPI over its unix socket. Lightweight, pure Swift, async/await, no shelling out, no second node. |
| Make your app **its own tailnet node** (no Tailscale install required; own identity; dial/listen on the tailnet) | [TailscaleKit / libtailscale](https://github.com/tailscale/libtailscale/tree/main/swift) (official) | Embeds a userspace tsnet node in your process. Heavier, but self-contained. |
| **Administer a tailnet** — devices, ACLs, DNS, auth keys — from a server or script | [Tailscale API](https://tailscale.com/api) (`api.tailscale.com`) | Cloud admin REST API with published OpenAPI spec; any HTTP client works. It manages the tailnet, not the local machine. |
| Quick one-off automation on a machine with Tailscale installed | `tailscale` CLI (shell out) | Fine for scripts. This package exists so apps don't have to parse CLI output or spawn processes. |

Rules of thumb: if Tailscale is already installed and you want to observe or control it → this package. If your app must *be* a tailnet node → TailscaleKit. If you're managing the tailnet itself (not a device) → the api.tailscale.com admin API.

> **Note:** The LocalAPI is not a formally stable interface — Tailscale namespaces it `/localapi/v0/` for a reason. This package tracks upstream, states which Tailscale versions each release was tested against, and uses tolerant decoding so upstream additions don't break your app. See the [stability policy](ROADMAP.md#stability--support-tiers).

## Installation

```swift
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.12.0")
```

Or in Xcode: **File → Add Package Dependencies…** and enter the repository URL.

## Get Tailscale status from a Swift app

```swift
import TailscaleClient

let client = TailscaleClient()  // auto-discovers the LocalAPI (unix socket first)

let status = try await client.status()
print(status.selfNode?.hostName ?? "unknown")
print("Backend: \(status.backendState?.rawValue ?? "?")")  // "Running", "Stopped", ...
print("Interface: \(status.interfaceName ?? "n/a")")  // e.g., "utun16"

let whoIs = try await client.whois(address: "100.64.0.5")
print(whoIs.userProfile?.displayName ?? "unknown user")
```

## Watch Tailscale state changes without polling

```swift
// Real-time IPN bus stream — state, health, engine counters, netmap changes.
for try await notify in try await client.watchIPNBus(options: [.initialState, .initialHealthState]) {
    if let state = notify.state { print("State: \(state)") }
    if let health = notify.health { print("Health warnings: \(health.warnings ?? [:])") }
}
```

## Change Tailscale configuration safely

```swift
// Partial, typed writes: only the fields you set are touched.
var change = MaskedPrefs()
change.shieldsUp = true
let updated = try await client.editPrefs(change)

// Or validate a full prefs object first — the daemon checks, nothing applies.
try await client.checkPrefs(updated)
```

## Configure Tailscale Serve from Swift

```swift
// Snapshot → mutate → write, with ETag optimistic concurrency: a concurrent
// change by anyone else makes the write throw .preconditionFailed.
var serve = try await client.serveConfig()
serve.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
try await client.setServeConfig(serve)
```

See the DocC articles for the full patterns: [*Writing Safely*](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/writingsafely), [*Streaming*](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/streaming), and [*Serve, Funnel & Certificates*](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/serveandfunnel).

## Runtime support

"Compiles" and "can actually talk to a daemon" are different claims; this table makes both explicit.

| Platform | Builds (CI-verified) | Connects to a local tailscaled |
|---|---|---|
| macOS 13+ | ✅ hosted CI | ✅ unix socket + opt-in App Store loopback — integration-tested against a real daemon in CI |
| Linux | ✅ hosted CI | ✅ unix socket — hermetically integration-tested against headscale + real tailscaled (stable / previous-stable / unstable) in CI |
| iOS 16+, tvOS 16+, watchOS 9+ | ✅ build-only CI | ❌ no reachable daemon on-device — Tailscale's iOS app runs as a network extension whose LocalAPI third-party apps cannot reach. Declared so shared/multi-platform targets compile; useful for model code, not live connections. |

## Status

**Current release: v0.12.0** — Always-on gap-fill & 1.0 runway: `services()` (Tailscale Services state) and `shutdownTailscaled()` wrap the last always-registered LocalAPI handlers; `startFreshProfile(controlURL:)` completes the interactive login lifecycle (proven end-to-end against headscale in CI); Linux `interfaceName`/`interfaceInfo` discovery; test-coverage floor raised to 85% and documentation-coverage floors in CI; model-conformance and full upstream-handler inventory gates; weekly upstream-drift automation; a menu-bar DocC tutorial.

The full version-by-version history lives in [`CHANGELOG.md`](CHANGELOG.md). The path to 1.0 — API freeze, ≥85% coverage, complete DocC tree — is laid out in [`ROADMAP.md`](ROADMAP.md), with the endpoint-by-endpoint matrix in [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md).

## CLI

The package ships `tailscale-swift`, a CLI for inspecting a local daemon — every library feature, scriptable via `--json`:

```bash
# From a checkout
swift run tailscale-swift status

# Or install the release build
swift build -c release --product tailscale-swift

# Homebrew
brew tap dweekly/tap && brew install tailscale-swift
```

Subcommands: `status`, `whois`, `prefs`, `ping`, `health`, `metrics`, `usermetrics`, `watch`, `features`, `derpmap`, `suggest-exit`, `netcheck`, `dns status`, `dns query`, `check-forwarding`, `serve status`, `cert domains`, `set …`, `login`, `logout`, `switch`. All structured commands accept `--json`.

> **Using an AI coding agent?** [`Documentation/INTEGRATING.md`](Documentation/INTEGRATING.md) is the canonical integration guide for humans and agents alike; this repo also ships a [Claude Code skill](.claude/skills/swift-tailscale-client/SKILL.md), a root [`AGENTS.md`](AGENTS.md), and Copilot instructions that all point there.

Looking for a working starting point? [`Examples/StatusDemo`](Examples/StatusDemo) is a standalone package that connects, prints status, probes daemon features, and runs a netcheck — CI builds it on macOS and Linux and runs it against a real daemon.

## API Reference

| Method | Description |
|--------|-------------|
| `status(query:)` | Fetch current node status, peers, and tailnet info |
| `whois(address:)` | Look up identity information for a Tailscale IP |
| `prefs()` | Get current node preferences and configuration |
| `ping(ip:type:size:)` | Ping a peer to test connectivity and measure latency |
| `metrics()` | Fetch internal metrics in Prometheus exposition format |
| `userMetrics()` | Fetch stable user-facing metrics (Prometheus format, `tailscale metrics print` equivalent) |
| `derpMap()` | Fetch the DERP relay map (regions, nodes, STUN/DERP ports) |
| `suggestExitNode(forceProbe:)` | Ask the daemon which exit node it would pick right now |
| `netcheck(options:)` | Client-side STUN probe of every DERP region: latency, public IP, NAT hardness, UDP reachability |
| `dnsOSConfig()` / `dnsConfig()` | Installed OS DNS state / the tailnet's DNS intent from the netmap |
| `dnsQuery(name:type:)` | Resolve a name through tailscaled's forwarder (the MagicDNS path) |
| `checkIPForwarding()` | Subnet-router / exit-node readiness preflight |
| `peer(byID:)` / `userProfile(byID:)` | Resolve numeric node and user IDs to full records |
| `experimental.bugreport()` / `.goroutines()` / `.logtap()` | SemVer-exempt debug surfaces (markers, stack dumps, live log stream) |
| `editPrefs(_:)` | Apply a partial preferences change (typed `MaskedPrefs`; the `tailscale set` mechanism) |
| `checkPrefs(_:)` | Validate a full preferences object without applying it |
| `setUseExitNode(enabled:)` | Toggle the selected exit node on/off |
| `setExpirySooner(_:)` / `reloadConfig()` / `start(options:)` | Key hygiene, config reload, backend start (headless auth-key bring-up) |
| `loginInteractive()` / `logout()` / `resetAuth()` | Auth lifecycle (BrowseToURL arrives on the IPN bus) |
| `profiles()` / `switchProfile(_:)` / … | Multi-account profile management |
| `idToken(audience:)` | OIDC ID token from the control plane |
| `serveConfig()` / `setServeConfig(_:)` | Serve/Funnel config snapshot + ETag-guarded replace (stale writes throw `.preconditionFailed`) |
| `certDomains()` / `certPEM(domain:kind:minValidity:)` / `certPair(domain:minValidity:)` | Tailnet TLS domains and certificate material |
| `setDNS(name:value:)` / `queryFeature(_:)` | ACME dns-01 TXT records; control-plane feature probes |
| `watchIPNBus(options:reconnect:onUndecodableLine:)` | Stream real-time state changes (returns `AsyncThrowingStream<IPNNotify, Error>`); opt-in auto-reconnect with backoff |
| `daemonFeatures()` | Probe which optional features the daemon was compiled with (`debug-optional-features`) |

| Property | Description |
|----------|-------------|
| `StatusResponse.interfaceName` | The TUN interface name (e.g., "utun16") discovered by matching Tailscale IPs |
| `StatusResponse.interfaceInfo` | Full interface details including up/running state and interface type |

All methods are async and throw `TailscaleClientError` on failure. Errors include actionable recovery suggestions.

### LocalAPI Discovery

By default, `TailscaleClient()` discovers the LocalAPI via Unix domain sockets, which works with:
- **Homebrew**: `brew install tailscale` → `/var/run/tailscaled.socket`
- **System Extension**: MDM-managed → `/Library/Tailscale/Data/tailscaled.sock`
- **Standalone tailscaled**: Any Unix socket path

This default behavior does **not** trigger any macOS permission popups.

#### macOS App Store Version

If your users have the **App Store version** of Tailscale (not Homebrew), you must explicitly opt-in to Group Container discovery:

```swift
// WARNING: This triggers a TCC permission popup on macOS!
let config = TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)
let client = TailscaleClient(configuration: config)
```

When enabled, the library scans Group Containers to find `sameuserproof-<port>-<token>` files. This triggers a macOS popup asking the user to allow access to another app's data. Only enable this if:
- Your users have the App Store version of Tailscale
- You have explained to users why this permission is needed
- Unix socket discovery has failed

#### Environment Variable Overrides

| Environment variable | Purpose |
| --- | --- |
| `TAILSCALE_LOCALAPI_SOCKET` | Override Unix socket path |
| `TAILSCALE_LOCALAPI_PORT` / `TAILSCALE_LOCALAPI_HOST` | Connect via loopback TCP |
| `TAILSCALE_LOCALAPI_URL` | Full base URL override |
| `TAILSCALE_LOCALAPI_AUTHKEY` | Auth token for TCP connections |
| `TAILSCALE_LOCALAPI_CAPABILITY` | Capability version (defaults to `144`, the pinned tested value) |
| `TAILSCALE_DISCOVERY_DEBUG` | Set to `1` to log discovery decisions |

#### App Store Discovery Options (when enabled)

| Environment variable | Purpose |
| --- | --- |
| `TAILSCALE_SAMEUSER_PATH` | Explicit path to `sameuserproof-*` file |
| `TAILSCALE_SAMEUSER_DIR` | Restrict Group Container scanning to specific directory |
| `TAILSCALE_SKIP_LIBPROC` | Set to `1` to skip libproc, use filesystem scan only |

## Testing

- Unit tests rely on mock transports and sanitized JSON fixtures; run with `swift test`.
- Integration tests that talk to a real tailscaled instance are opt-in. Ensure Tailscale is running locally, then execute:
  ```bash
  TAILSCALE_INTEGRATION=1 swift test --filter TailscaleClientIntegrationTests
  ```
  You can also override socket or loopback settings using the environment variables above.
- CI runs the mock-backed suites on hosted macOS and Linux runners (plus a Thread Sanitizer lane), the real-daemon integration suite on a self-hosted Mac, and a nightly hermetic integration matrix against headscale + real tailscaled. See [`Documentation/TESTING.md`](Documentation/TESTING.md).

## Contributing

Community contributions are welcome! Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) for guidelines on coding style, testing, and documentation expectations. By participating you agree to abide by the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

MIT © 2025 David E. Weekly
