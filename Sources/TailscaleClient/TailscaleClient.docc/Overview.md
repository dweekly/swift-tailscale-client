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
- <doc:ServeAndFunnel>
- <doc:StabilityTiers>
- <doc:VersionCompatibility>
- <doc:MigrationFrom012>

### Recipes (compiled from Examples/Recipes)
- <doc:RecipeMenuBar>
- <doc:RecipeMonitoring>
- <doc:RecipeExitNode>
- <doc:RecipeServe>
- <doc:RecipeTesting>

### Essentials
- ``TailscaleClient``
- ``TailscaleClientConfiguration``
- ``TailscaleClientError``
- ``LocalAPIDiscovery``
- ``LocalAPIDiscoveryError``
- ``TailscaleEndpoint``
- ``EndpointSource``

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
- ``IPNBusEvent``
- ``IPNBusLifecycle``
- ``IPNNotify``
- ``IPNState``
- ``EngineStatus``
- ``HealthState``
- ``HealthWarning``
- ``NotifyWatchOpt``
- ``IPNBusReconnectPolicy``
- ``StreamRetryPolicy``
- ``StreamBufferBounds``
- ``StreamOverflowStrategy``
- ``StreamErrorClassification``
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
- ``WhoIsIPProtocol``

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
- ``VersionDiagnostics``

### DNS & Routing Diagnostics
- ``DNSOSConfig``
- ``DNSConfig``
- ``DNSRecord``
- ``DNSQueryResponse``
- ``DNSResolver``
- ``IPForwardingCheck``

### Serve, Funnel & Certificates
- ``ServeConfigSnapshot``
- ``ServeConfig``
- ``TCPPortHandler``
- ``WebServerConfig``
- ``HTTPHandler``
- ``ServiceConfig``
- ``CertPair``
- ``CertKind``
- ``QueryFeatureResponse``

### Experimental (SemVer-Exempt)
- ``ExperimentalClient``
- ``LogtapEntry``

### Network Interface Discovery
- ``NetworkInterfaceDiscovery``

### Transport
- ``StreamingResponse``
- ``TailscaleTransport``
- ``TailscaleTransportError``
- ``TailscaleRequest``
- ``TailscaleResponse``
- ``URLSessionTailscaleTransport``
