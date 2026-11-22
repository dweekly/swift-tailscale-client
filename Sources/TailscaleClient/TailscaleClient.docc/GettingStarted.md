# Getting Started

Connect to a running Tailscale daemon and make your first queries.

## Overview

`swift-tailscale-client` talks to the Tailscale daemon (`tailscaled`) that is
already installed on the machine, over its LocalAPI. It does not create a
tailnet node of its own — if you need that, use Tailscale's official
TailscaleKit instead.

## Add the package

```swift
// Package.swift
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "1.1.0"),

// target dependencies:
.product(name: "TailscaleClient", package: "swift-tailscale-client"),
```

## First queries

`TailscaleClient()` discovers the LocalAPI automatically (see
<doc:DiscoveryAndPermissions>) and every method is a straightforward
async call:

```swift
import TailscaleClient

let client = TailscaleClient()

let status = try await client.status()
print(status.selfNode?.hostName ?? "unknown", status.backendState ?? .other)

let whois = try await client.whois(address: "100.64.0.5")
print(whois.userProfile?.displayName ?? "unknown user")

let ping = try await client.ping(ip: "100.64.0.5")
print(ping.latencyDescription ?? "no reply")
```

For real-time updates, prefer streaming over polling — see <doc:Streaming>.

## Testing your integration

Add the `TailscaleClientMocks` product to your test target and inject a
``TailscaleTransport``-conforming mock; no daemon required:

```swift
import TailscaleClientMocks

let transport = MockTransport { request, _ in
  TailscaleResponse(statusCode: 200, data: fixtureJSON)
}
let config = TailscaleClientConfiguration(
  endpoint: .url(URL(string: "http://mock.local")!),
  authToken: nil,
  transport: transport)
let client = TailscaleClient(configuration: config)
```

## Try the sample app first

`Examples/PeerDiagnostics` is a small Mac app that lists your peers and shows
how a ping reached the one you select. It opens with a built-in, made-up
tailnet, so it runs without Tailscale installed:

```
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics
```

Choose **Live** in the window to switch to the daemon on your Mac (read-only).
<doc:RecipePeerDiagnostics> walks through the code worth copying.

## Working example

The repository also ships `Examples/StatusDemo`, a standalone package that
connects, prints status, probes daemon features, and runs a netcheck — CI
builds it on macOS, so it is
always current. Copy it as a starting point and swap the path dependency for
the released URL.
