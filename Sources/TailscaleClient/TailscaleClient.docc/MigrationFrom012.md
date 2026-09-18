# Migrating from 0.12.x to 1.0

Step-by-step migration guide for upgrading projects to swift-tailscale-client 1.0.

## Overview

Version 1.0 of `swift-tailscale-client` is a major release introducing safe configuration concurrency, bounded streaming resources, asynchronous discovery across all macOS installation flavors and Linux, and comprehensive error taxonomy.

This guide outlines the breaking changes, deprecated symbol removals, and recommended upgrade paths for existing applications built with 0.12.x.

### Safe Serve Configuration Updates

In 0.12.x, `serveConfig()` returned a mutable `ServeConfig` that dropped unmodeled JSON fields, and `setServeConfig(_:)` wrote the document back blindly, risking overwriting concurrent changes made by the GUI or other tools.

In 1.0, Serve configuration uses optimistic concurrency with ETag validation:

#### Old (0.12.x):
```swift
var config = try await client.serveConfig()
config.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
try await client.setServeConfig(config)
```

#### New (1.0):
```swift
// Fetch snapshot with concurrency token
let snapshot = try await client.serveConfigSnapshot()

// Apply changes conditionally
let updated = try await client.updateServeConfig(snapshot) { config in
  config.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
}
```

If another client modified the configuration concurrently, `setServeConfig(_:matching:)` and `updateServeConfig(_:mutate:)` throw ``TailscaleClientError/preconditionFailed(body:endpoint:)`` (HTTP 412).

If you intentionally want an unconditional overwrite without ETag checking, use ``TailscaleClient/replaceServeConfigUnconditionally(_:)``.

### IPN Bus Streaming and Lifecycle Events

In 0.12.x, `watchIPNBus()` yielded raw `IPNNotify` values. Connection drops and reconnections were hidden, and slow consumers could cause unbounded memory growth.

In 1.0, `watchIPNBusEvents` yields ``IPNBusEvent`` objects that distinguish daemon notifications from transport lifecycle events, with explicit buffer bounds:

#### Old (0.12.x):
```swift
for try await notify in try await client.watchIPNBus(reconnect: .default) {
  if let state = notify.state { print(state) }
}
```

#### New (1.0):
```swift
let events = try await client.watchIPNBusEvents(
  options: .default,
  retryPolicy: .default,
  bounds: StreamBufferBounds(maxEventCount: 256, overflowStrategy: .reportGap)
)

for try await event in events {
  switch event {
  case .notification(let notify):
    if let state = notify.state { print("State:", state) }
  case .lifecycle(let lifecycle):
    switch lifecycle {
    case .connected:
      print("Stream connected")
    case .disconnected(let reason):
      print("Disconnected: \(reason)")
    case .retrying(let attempt, let delay):
      print("Retrying in \(delay) (attempt \(attempt))")
    case .stateGap(let reason):
      print("Buffer gap occurred (\(reason)); state refreshed")
    }
  }
}
```

Legacy `watchIPNBus(options:reconnect:onUndecodableLine:)` remains available for pure notification loops.

### Profile Management: addProfile Removal

The deprecated `addProfile()` method has been removed in 1.0. Upstream Tailscale LocalAPI does not support creating arbitrary named profiles directly; instead, switching to a new profile is accomplished via `switchToEmptyProfile()`.

#### Old (0.12.x):
```swift
try await client.addProfile() // Removed in 1.0
```

#### New (1.0):
```swift
try await client.switchToEmptyProfile()
```

### Asynchronous Discovery and Credential Recovery

In 0.12.x, discovery was strictly synchronous and did not support standalone macOS `.pkg` installations. In 1.0:

- Use ``LocalAPIDiscovery/discoverAsync()`` for non-blocking asynchronous discovery.
- Standalone `.pkg` installations (`/Library/Tailscale/ipnport` symlink & token) are discovered natively without macOS TCC prompts.
- When using automatic discovery, the client monitors daemon restarts and automatically re-probes credentials on `ECONNREFUSED` or HTTP 401/403.

```swift
let discovery = LocalAPIDiscovery()
let result = try await discovery.discoverAsync()
```

### Expanded Error Taxonomy

1.0 introduces typed errors for all LocalAPI failure modes:
- ``TailscaleClientError/preconditionFailed(body:endpoint:)`` (HTTP 412)
- ``TailscaleClientError/missingConcurrencyToken``
- ``TailscaleClientError/streamOverflow``
- ``TailscaleClientError/discovery(_:)`` wrapping ``LocalAPIDiscoveryError``
- ``TailscaleClientError/permissionDenied(body:endpoint:)`` (HTTP 403)
- ``TailscaleClientError/rateLimited(retryAfterSeconds:body:endpoint:)`` (HTTP 429)
- ``TailscaleClientError/peerNotFound(endpoint:)`` (HTTP 404)

Review your error-handling code to catch these specific cases and display their `recoverySuggestion` to users.

## Topics

### Concurrency
- ``ServeConfigSnapshot``
- ``ServeConfig``

### Streaming
- ``IPNBusEvent``
- ``IPNBusLifecycle``
- ``StreamRetryPolicy``
- ``StreamBufferBounds``

### Errors
- ``TailscaleClientError``
- ``LocalAPIDiscoveryError``
