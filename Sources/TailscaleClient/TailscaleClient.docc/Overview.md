# ``TailscaleClient``

Unofficial Swift 6 interface for the Tailscale LocalAPI, providing async/await access to status, identity lookup, preferences, ping, and metrics endpoints.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

## Overview

This library connects to an existing Tailscale daemon to query its state and configuration. It's designed for building monitoring tools, status widgets, dashboards, and developer utilities.

```swift
import TailscaleClient

let client = TailscaleClient()

// Get current status and interface name
let status = try await client.status()
print(status.selfNode?.hostName ?? "unknown")
print("Interface: \(status.interfaceName ?? "unknown")")  // e.g., "utun16"

// Look up a peer by IP
let whoIs = try await client.whois(address: "100.64.0.5")
print(whoIs.userProfile?.displayName ?? "unknown")

// Ping a peer
let ping = try await client.ping(ip: "100.64.0.5")
print("Latency: \(ping.latencyDescription ?? "n/a")")
```

## Topics

### Articles
- <doc:GettingStarted>
- <doc:DiscoveryAndPermissions>
- <doc:Streaming>
- <doc:ErrorHandling>
- <doc:WritingSafely>
- <doc:LoginFlow>
- <doc:StabilityTiers>
- <doc:VersionCompatibility>

### Essentials
- ``TailscaleClient``
- ``TailscaleClientConfiguration``
- ``TailscaleClientError``
- ``LocalAPIDiscovery``
- ``TailscaleEndpoint``

### Status
- ``StatusResponse``
- ``StatusQuery``
- ``NodeStatus``
- ``BackendState``
- ``TailnetStatus``
- ``ClientVersionStatus``
- ``CapabilityValue``
- ``JSONValue``

### Real-Time Updates (IPN Bus)
- ``IPNNotify``
- ``IPNState``
- ``EngineStatus``
- ``HealthState``
- ``HealthWarning``
- ``NotifyWatchOpt``
- ``IPNBusReconnectPolicy``
- ``PartialFile``
- ``OutgoingFile``
- ``EmptyMessage``

### Capability Probing
- ``OptionalFeatures``

### Identity Lookup
- ``WhoIsResponse``
- ``WhoIsNode``
- ``WhoIsHostinfo``
- ``UserProfile``

### Auth & Profiles
- ``LoginProfile``
- ``NetworkProfile``

### Preferences
- ``Prefs``
- ``MaskedPrefs``
- ``ReloadConfigResult``
- ``StartOptions``
- ``AutoUpdatePrefs``
- ``AppConnectorPrefs``

### Connectivity Testing
- ``PingResult``
- ``PingType``

### Network Diagnostics
- ``DERPMap``
- ``DERPHomeParams``
- ``DERPRegion``
- ``DERPNode``
- ``ExitNodeSuggestion``
- ``NodeLocation``
- ``Netcheck``
- ``NetcheckReport``

### DNS & Routing Diagnostics
- ``DNSOSConfig``
- ``DNSQueryResponse``
- ``DNSResolver``
- ``IPForwardingCheck``

### Experimental (SemVer-Exempt)
- ``ExperimentalClient``
- ``LogtapEntry``

### Network Interface Discovery
- ``NetworkInterfaceDiscovery``

### Transport
- ``TailscaleTransport``
- ``TailscaleTransportError``
- ``TailscaleRequest``
- ``TailscaleResponse``
- ``URLSessionTailscaleTransport``
