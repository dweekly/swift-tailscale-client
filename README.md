# swift-tailscale-client

[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS-lightgray.svg)](https://github.com/dweekly/swift-tailscale-client)
[![License MIT](https://img.shields.io/github/license/dweekly/swift-tailscale-client)](LICENSE)
[![CI](https://github.com/dweekly/swift-tailscale-client/workflows/CI/badge.svg)](https://github.com/dweekly/swift-tailscale-client/actions)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blue)](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/)

> Unofficial Swift 6 client for the Tailscale LocalAPI

`swift-tailscale-client` is a personal, MIT-licensed project by David E. Weekly. It is **not** an official Tailscale product and is not endorsed by Tailscale Inc. The goal is to provide an idiomatic async/await Swift interface to the LocalAPI so Apple-platform apps can query Tailscale state without shelling out to the `tailscale` CLI.

## What This Package Does

This package **connects to an existing tailscaled daemon** to query its state and configuration. It's designed for building monitoring tools, status widgets, dashboards, and developer utilities that work with an existing Tailscale installation.

**This is NOT an embedded Tailscale implementation.** If you need to embed Tailscale directly into your application (making your app its own tailnet node), see Tailscale's official [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift) instead.

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

## Status
- **v0.2.1:** Network interface discovery - identify which TUN interface (e.g., `utun16`) Tailscale is using via `status.interfaceName`.
- **v0.2.0:** Added `whois()`, `prefs()`, `ping()`, and `metrics()` endpoints. Pure Swift libproc-based LocalAPI discovery (no shell-outs). Comprehensive test coverage.
- **v0.1.1:** Improved error handling with actionable messages, CLI exit node display with connection quality details.
- **v0.1.0:** `TailscaleClient.status()` API that fetches `/localapi/v0/status` and decodes the response into strongly typed Swift models.
- Future roadmap items (Taildrop, streaming IPN bus, etc.) are tracked in [`ROADMAP.md`](ROADMAP.md).

## Installation
Add the package to your `Package.swift` dependencies (once published):

```swift
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.1.0")
```

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
```

## API Reference

| Method | Description |
|--------|-------------|
| `status(query:)` | Fetch current node status, peers, and tailnet info |
| `whois(address:)` | Look up identity information for a Tailscale IP |
| `prefs()` | Get current node preferences and configuration |
| `ping(ip:type:size:)` | Ping a peer to test connectivity and measure latency |
| `metrics()` | Fetch internal metrics in Prometheus exposition format |

| Property | Description |
|----------|-------------|
| `StatusResponse.interfaceName` | The TUN interface name (e.g., "utun16") discovered by matching Tailscale IPs |
| `StatusResponse.interfaceInfo` | Full interface details including up/running state and interface type |

All methods are async and throw `TailscaleClientError` on failure. Errors include actionable recovery suggestions.

### Configuration Overrides
### macOS LocalAPI Discovery
On macOS the client automatically discovers the App Store GUI's loopback LocalAPI by locating `sameuserproof-<port>-<token>` files. Discovery uses a two-tier strategy:

1. **libproc** (primary, ~5ms): Uses `proc_pidinfo` to find the IPNExtension process's open files. This works because IPNExtension runs as the current user.
2. **Filesystem scan** (fallback, ~50-200ms): Enumerates `~/Library/Group Containers` for Tailscale directories.

Useful environment variables:

| Environment variable | Purpose |
| --- | --- |
| `TAILSCALE_DISCOVERY_DEBUG` | Set to `1` to log discovery decisions. |
| `TAILSCALE_SAMEUSER_PATH` | Override with an explicit path to a `sameuserproof-*` file. |
| `TAILSCALE_SAMEUSER_DIR` | Restrict scanning to a specific directory. |
| `TAILSCALE_SKIP_LIBPROC` | Set to `1` to skip libproc and use filesystem scan only. |

`TailscaleClient` discovers how to talk to the LocalAPI using environment variables. These are handy when running in CI or when the default Unix socket path is unavailable.

| Environment variable | Purpose |
| --- | --- |
| `TAILSCALE_LOCALAPI_SOCKET` | Override the Unix domain socket path (defaults to `/var/run/tailscale/tailscaled.sock`). |
| `TAILSCALE_LOCALAPI_PORT` / `TAILSCALE_LOCALAPI_HOST` | Connect via loopback TCP (requires `TAILSCALE_LOCALAPI_AUTHKEY`). |
| `TAILSCALE_LOCALAPI_URL` | Provide a full base URL (e.g. `http://127.0.0.1:41112`). |
| `TAILSCALE_LOCALAPI_AUTHKEY` | Basic-auth token used when connecting over TCP. |
| `TAILSCALE_LOCALAPI_CAPABILITY` | Custom capability version to advertise (defaults to `1`). |

## Testing
- Unit tests rely on mock transports and sanitized JSON fixtures; run with `swift test`.
- Integration tests that talk to a real tailscaled instance are opt-in. Ensure Tailscale is running locally, then execute:
  ```bash
  TAILSCALE_INTEGRATION=1 swift test --filter TailscaleClientIntegrationTests
  ```
  You can also override socket or loopback settings using the environment variables above.
- GitHub Actions will execute only the mock-backed suites to keep CI hermetic.

## Contributing
Community contributions are welcome! Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) for guidelines on coding style, testing, and documentation expectations. By participating you agree to abide by the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License
MIT © 2025 David E. Weekly
