# Error Handling

What each error case means and how to respond to it.

## Overview

All operations in `swift-tailscale-client` throw strongly typed errors providing diagnostic context and actionable recovery suggestions. Understanding the error taxonomy allows applications to gracefully handle daemon restarts, concurrency conflicts, and permission constraints.

### The Error Taxonomy: All 12 Error Cases

`TailscaleClient` methods throw ``TailscaleClientError``, which enumerates 12 distinct failure modes:

1. ``TailscaleClientError/transport(_:)``: Communication failure at the socket or HTTP layer (socket file missing, connection refused, or broken pipe). Usually indicates the Tailscale daemon is stopped or uninstalled.
2. ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)``: The daemon returned an unmapped HTTP status code. The raw response body is attached for diagnosis.
3. ``TailscaleClientError/decoding(_:body:endpoint:)``: The response payload could not be decoded into Swift models. The raw body is preserved to help isolate schema changes.
4. ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``: The endpoint is not implemented or was compiled out of this daemon build.
5. ``TailscaleClientError/timeout(endpoint:)``: The configured `requestTimeout` elapsed before the daemon responded.
6. ``TailscaleClientError/preconditionFailed(body:endpoint:)``: The daemon rejected a conditional write (HTTP 412) because another client updated the configuration concurrently and the provided ETag was stale.
7. ``TailscaleClientError/permissionDenied(body:endpoint:)``: Access denied by tailnet policy or operating system permissions (HTTP 403). Some policies allow operations when supplied with an audit justification via ``TailscaleClient/withAuditReason(_:operation:)``.
8. ``TailscaleClientError/rateLimited(retryAfterSeconds:body:endpoint:)``: The daemon throttled the request (HTTP 429). `retryAfterSeconds` contains the duration specified in the `Retry-After` header when available.
9. ``TailscaleClientError/peerNotFound(endpoint:)``: The daemon answered a peer lookup with HTTP 404 because no peer matches the queried IP address or key.
10. ``TailscaleClientError/missingConcurrencyToken``: A conditional configuration update was attempted on a snapshot that had an empty or missing ETag.
11. ``TailscaleClientError/streamOverflow``: An IPN bus event stream queue exceeded its configured ``StreamBufferBounds`` and the overflow policy was set to ``StreamOverflowStrategy/fail``.
12. ``TailscaleClientError/discovery(_:)``: Automatic discovery failed to locate an accessible LocalAPI endpoint. Wraps a ``LocalAPIDiscoveryError``.

### Handling Concurrency Conflicts (preconditionFailed)

When modifying shared configuration such as Serve or Funnel, concurrent clients could overwrite each other's changes. `TailscaleClient` enforces optimistic concurrency control using ``ServeConfigSnapshot``:

```swift
do {
  let snapshot = try await client.serveConfigSnapshot()
  var config = snapshot.config
  config.allowFunnel = [8443: true]
  _ = try await client.setServeConfig(config, matching: snapshot)
} catch TailscaleClientError.preconditionFailed {
  // Another process changed config in the meantime; re-fetch and re-apply
}
```

### Handling Permission Restrictions (permissionDenied)

Certain operations (such as reconfiguring routing or clearing network preferences) require administrative privileges or security justifications. If an operation fails with `.permissionDenied`, use ``TailscaleClient/withAuditReason(_:operation:)`` to attach an audit log reason:

```swift
try await client.withAuditReason("Automated failover by orchestration agent") {
  try await client.setPrefs(maskedPrefs)
}
```

### Rate Limiting and Retry-After (rateLimited)

Endpoints that interact with the Tailscale control plane or issue TLS certificates (e.g., `certPair`) may be rate-limited by the daemon:

```swift
do {
  let certs = try await client.certPair(domain: "my-node.example.ts.net")
} catch let TailscaleClientError.rateLimited(retryAfter, _, _) {
  if let delay = retryAfter {
    print("Rate limited; retry after \(delay) seconds")
  }
}
```

### LocalAPI Discovery Errors

When using automatic discovery, failures surface as ``TailscaleClientError/discovery(_:)`` wrapping a ``LocalAPIDiscoveryError``:

- ``LocalAPIDiscoveryError/notInstalled``: No Tailscale installation found on the machine.
- ``LocalAPIDiscoveryError/stopped(candidate:)``: The daemon was found but is not listening on its socket or port.
- ``LocalAPIDiscoveryError/inaccessible(path:reason:)``: The socket or proof file exists but cannot be read due to file permissions or sandbox restrictions.
- ``LocalAPIDiscoveryError/invalidCredentials(endpoint:)``: The loopback API rejected credentials (HTTP 401/403).

Every discovery error provides a detailed `recoverySuggestion` explaining how to resolve the issue (e.g., starting the daemon or granting group permissions).

### The Two Meanings of 404 and peerNotFound

LocalAPI uses HTTP 404 both for non-existent endpoints and missing entities:
- For optional endpoints not built into the daemon, the client translates 404 to ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.
- For whois and peer lookups, a missing node translates to ``TailscaleClientError/peerNotFound(endpoint:)``.

### Probing Feature Availability

Rather than catching errors when invoking optional endpoints, probe feature support in advance using ``TailscaleClient/daemonFeatures()``:

```swift
let features = try await client.daemonFeatures()
if features.isEnabled("use-exit-node") {
  let suggestion = try await client.suggestExitNode()
}
```

### Resilient Error Handling Pattern

```swift
do {
  let status = try await client.status()
  render(status)
} catch let error as TailscaleClientError {
  switch error {
  case .transport(let transportError):
    showBanner("Tailscale connection error: \(transportError.localizedDescription)")
  case .discovery(let discoveryError):
    showBanner(discoveryError.localizedDescription, detail: discoveryError.recoverySuggestion)
  case .preconditionFailed:
    retryUpdate()
  case .permissionDenied:
    promptForAdminCredentials()
  default:
    log(error.localizedDescription)
  }
}
```

## Topics

### Error Types
- ``TailscaleClientError``
- ``LocalAPIDiscoveryError``
- ``TailscaleTransportError``

### Concurrency & Streaming Models
- ``ServeConfigSnapshot``
- ``StreamBufferBounds``
- ``StreamOverflowStrategy``

