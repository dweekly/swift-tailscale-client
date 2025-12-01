# ``TailscaleClient``

Unofficial Swift 6 interface for the Tailscale LocalAPI, providing async/await access to status, identity lookup, preferences, ping, and metrics endpoints.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

## Overview

This library connects to an existing Tailscale daemon to query its state and configuration. It's designed for building monitoring tools, status widgets, dashboards, and developer utilities.

```swift
import TailscaleClient

let client = TailscaleClient()

// Get current status
let status = try await client.status()
print(status.selfNode?.hostName ?? "unknown")

// Look up a peer by IP
let whoIs = try await client.whois(address: "100.64.0.5")
print(whoIs.userProfile?.displayName ?? "unknown")

// Ping a peer
let ping = try await client.ping(ip: "100.64.0.5")
print("Latency: \(ping.latencyDescription ?? "n/a")")
```

## Topics

### Essentials
- ``TailscaleClient``
- ``TailscaleClientConfiguration``
- ``TailscaleClientError``

### Status
- ``StatusResponse``
- ``StatusQuery``
- ``NodeStatus``
- ``BackendState``

### Identity Lookup
- ``WhoIsResponse``
- ``WhoIsNode``
- ``WhoIsHostinfo``
- ``UserProfile``

### Preferences
- ``Prefs``
- ``AutoUpdatePrefs``
- ``AppConnectorPrefs``

### Connectivity Testing
- ``PingResult``
- ``PingType``

### Transport
- ``TailscaleTransport``
- ``TailscaleTransportError``
