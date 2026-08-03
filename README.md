# swift-tailscale-client

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdweekly%2Fswift-tailscale-client%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/dweekly/swift-tailscale-client)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdweekly%2Fswift-tailscale-client%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/dweekly/swift-tailscale-client)
[![License MIT](https://img.shields.io/github/license/dweekly/swift-tailscale-client)](LICENSE)
[![CI](https://github.com/dweekly/swift-tailscale-client/workflows/CI/badge.svg)](https://github.com/dweekly/swift-tailscale-client/actions)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blue)](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/)

> Unofficial Swift 6 client for the Tailscale LocalAPI

`swift-tailscale-client` is a personal, MIT-licensed project by David E. Weekly. It is **not** an official Tailscale product and is not endorsed by Tailscale Inc. The goal is to provide an idiomatic async/await Swift interface to the LocalAPI so Apple-platform apps can query Tailscale state without shelling out to the `tailscale` CLI.

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

### Use swift-tailscale-client when you want to:
- Build a menu bar app, widget, or dashboard showing Tailscale status
- Query peer information, connection state, exit nodes from Swift
- Monitor tailscaled without embedding the full Tailscale implementation
- Create developer tools that inspect or modify Tailscale configuration
- Integrate Tailscale status into existing apps (lightweight, pure Swift)

### Use TailscaleKit when you want to:
- Create a standalone service that joins a tailnet without installing Tailscale system-wide
- Build an app that acts as its own independent Tailscale node
- Distribute an application that includes Tailscale functionality
- Have multiple services with different Tailscale identities on the same device

> **Note:** The LocalAPI is not a formally stable interface — Tailscale namespaces it `/localapi/v0/` for a reason. This package tracks upstream, states which Tailscale versions each release was tested against, and uses tolerant decoding so upstream additions don't break your app. See the [stability policy](ROADMAP.md#stability--support-tiers).

## Status
- **v0.10.0:** Serve, Funnel & certificates - `serveConfig()`/`setServeConfig(_:)` with ETag optimistic concurrency (stale writes throw the typed `.preconditionFailed`), `certDomains()`/`certPEM()`/`certPair()`, `setDNS(name:value:)` (ACME dns-01), `queryFeature(_:)`; CLI `serve status` + `cert domains`; *Serve, Funnel & Certificates* article; Thread Sanitizer CI lane.
- **v0.9.0:** Auth & profiles - `loginInteractive()` (BrowseToURL via the IPN bus), `logout()`/`resetAuth()`, profiles CRUD with `LoginProfile` models, `idToken(audience:)`, experimental GUI-client contract, CLI `login`/`logout`/`switch`, *Login Flow* article.
- **v0.8.0:** First write APIs - `editPrefs(_:)` with the typed `MaskedPrefs` builder, `checkPrefs(_:)`, `setUseExitNode(enabled:)`, `setExpirySooner(_:)`, `reloadConfig()`, `start(options:)`; CLI `set` commands; *Writing Safely* DocC article; hermetic-only mutation testing.
- **v0.7.0:** DNS & routing diagnostics (`dnsOSConfig()`, `dnsQuery()`, `checkIPForwarding()`), numeric-ID lookups (`peer(byID:)`, `userProfile(byID:)`), the SemVer-exempt `client.experimental` namespace (`bugreport`, `goroutines`, streaming `logtap`), `dns`/`check-forwarding` CLI commands, and a six-article DocC set.
- **v0.6.0:** Network diagnostics - `derpMap()`, `suggestExitNode(forceProbe:)`, `userMetrics()`, and a native pure-Swift STUN `netcheck()` (per-region DERP latency, public IP, NAT hardness, UDP reachability). CLI became an installable product with `--json` everywhere; models are fully `Codable`; release binaries attached automatically.
- **v0.5.0:** Linux support (POSIX socket transport), unit-tested HTTP wire-format parsers, Linux CI, and nightly hermetic integration against headscale + real tailscaled.
- **v0.4.0:** Reliability foundations - shipped `TailscaleClientMocks` product, IPN stream hardening (skip-and-report + opt-in reconnect), `daemonFeatures()` capability probing, request timeouts, public inits and `Equatable` on all models.
- **v0.3.1:** Unix socket discovery takes priority (avoids TCC popups); macOS App Store discovery now opt-in; chunked HTTP support for Homebrew tailscaled.
- **v0.3.0:** IPN bus streaming - `watchIPNBus()` returns an `AsyncThrowingStream` for real-time state change notifications (eliminates polling).
- **v0.2.1:** Network interface discovery - identify which TUN interface (e.g., `utun16`) Tailscale is using via `status.interfaceName`.
- **v0.2.0:** Added `whois()`, `prefs()`, `ping()`, and `metrics()` endpoints. Pure Swift libproc-based LocalAPI discovery (no shell-outs). Comprehensive test coverage.
- **v0.1.1:** Improved error handling with actionable messages, CLI exit node display with connection quality details.
- **v0.1.0:** `TailscaleClient.status()` API that fetches `/localapi/v0/status` and decodes the response into strongly typed Swift models.
- The path to 1.0 — full LocalAPI coverage, Linux support, Homebrew CLI, hermetic integration testing — is laid out in [`ROADMAP.md`](ROADMAP.md), with the complete endpoint-by-endpoint matrix in [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md).

## Installation
Add the package to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.10.0")
```

Or in Xcode: **File → Add Package Dependencies…** and enter the repository URL.

### CLI

The package ships `tailscale-swift`, a CLI for inspecting a local daemon — every library feature, scriptable via `--json`:

```bash
# From a checkout
swift run tailscale-swift status

# Or install the release build
swift build -c release --product tailscale-swift

# Homebrew
brew tap dweekly/tap && brew install tailscale-swift
```

Subcommands: `status`, `whois`, `prefs`, `ping`, `health`, `metrics`, `usermetrics`, `watch`, `features`, `derpmap`, `suggest-exit`, `netcheck`, `dns status`, `dns query`, `check-forwarding`, `set …`, `login`, `logout`, `switch`. All structured commands accept `--json`.

> **Using an AI coding agent?** This repo ships a [Claude Code skill](.claude/skills/swift-tailscale-client/SKILL.md) that teaches agents what the package offers and how to integrate it correctly.

Looking for a working starting point? [`Examples/StatusDemo`](Examples/StatusDemo) is a standalone package that connects, prints status, probes daemon features, and runs a netcheck — CI builds it on macOS and Linux and runs it against a real daemon.

## Quickstart
```swift
import TailscaleClient

let client = TailscaleClient()

// Get current status and interface name
let status = try await client.status()
print(status.selfNode?.hostName ?? "unknown")
print("Interface: \(status.interfaceName ?? "unknown")")  // e.g., "utun16"

// Look up a peer by IP
let whoIs = try await client.whois(address: "100.64.0.5")
print(whoIs.userProfile?.displayName ?? "unknown user")

// Ping a peer
let ping = try await client.ping(ip: "100.64.0.5")
if ping.isSuccess {
    print("Latency: \(ping.latencyDescription ?? "n/a")")
}

// Get node preferences
let prefs = try await client.prefs()
print("Exit node: \(prefs.exitNodeID ?? "none")")

// Fetch Prometheus metrics
let metrics = try await client.metrics()
print(metrics)

// Stream real-time state changes
for try await notification in try await client.watchIPNBus() {
    if let state = notification.state {
        print("State changed: \(state)")
    }
    if let engine = notification.engine {
        print("Traffic: \(engine.rBytes) bytes received")
    }
}
```

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
| `TAILSCALE_LOCALAPI_CAPABILITY` | Capability version (defaults to `1`) |
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
- CI runs the mock-backed suites on hosted macOS and Linux runners, the real-daemon integration suite on a self-hosted Mac, and a nightly hermetic integration run against headscale + real tailscaled. See [`Documentation/TESTING.md`](Documentation/TESTING.md).

## Contributing
Community contributions are welcome! Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) for guidelines on coding style, testing, and documentation expectations. By participating you agree to abide by the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License
MIT © 2025 David E. Weekly
