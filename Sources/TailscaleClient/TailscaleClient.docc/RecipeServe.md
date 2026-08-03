# Recipe: Configure Serve and Retrieve Certificates

Add a TCP forward with ETag-safe concurrency, and fetch the node's TLS
credential.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

Every snippet below is compiled by CI from
[`Examples/Recipes`](https://github.com/dweekly/swift-tailscale-client/tree/main/Examples/Recipes).

## Add a forward, survive concurrent writers

```swift
/// Adds one TCP forward without disturbing anything else the node serves.
/// The snapshot-mutate-write loop retries when another writer (the
/// Tailscale CLI, a GUI) changes the config concurrently.
public func addTCPForward(port: UInt16, to target: String) async throws {
  let client = TailscaleClient()
  for _ in 0..<3 {
    var config = try await client.serveConfig()  // snapshot carries the ETag
    config.tcp[port] = TCPPortHandler(tcpForward: target)
    do {
      try await client.setServeConfig(config)
      return
    } catch TailscaleClientError.preconditionFailed {
      continue  // someone else won the race — rebase on their change and retry
    }
  }
  throw TailscaleClientError.preconditionFailed(
    body: Data(), endpoint: "/localapi/v0/serve-config")
}
```

`setServeConfig(_:)` **replaces** the whole configuration, which is exactly
why the snapshot must be fresh: building a `ServeConfig` from scratch would
silently delete every handler somebody else configured.

## Fetch the TLS credential

```swift
/// Fetches this node's TLS credential for its first cert domain. The first
/// call for a domain may block while the daemon completes ACME issuance,
/// so give the client a generous timeout.
public func fetchCertificate() async throws -> CertPair? {
  var configuration = TailscaleClientConfiguration.default
  configuration.requestTimeout = .seconds(120)
  let client = TailscaleClient(configuration: configuration)

  guard let domain = try await client.certDomains().first else {
    return nil  // HTTPS is not enabled for this tailnet
  }
  return try await client.certPair(domain: domain)
}
```

Never log `CertPair.privateKeyPEM`. Daemons built without ACME support throw
``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.

## See also

- <doc:ServeAndFunnel> — the full serve/Funnel model, including Funnel as a
  security decision and `queryFeature(_:)` probes.
