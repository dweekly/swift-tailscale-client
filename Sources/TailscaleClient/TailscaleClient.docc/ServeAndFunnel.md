# Serve, Funnel & Certificates

Read and modify what a node serves — safely, with optimistic concurrency —
and fetch its tailnet TLS certificates.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

## The serve config is one document

Unlike preferences (which patch field-by-field via ``MaskedPrefs``), the
daemon's serve/Funnel state is a single ``ServeConfig`` document that
`POST /serve-config` **replaces wholesale**. Always start from a fresh
snapshot, mutate it, and write it back:

```swift
let client = TailscaleClient()

var config = try await client.serveConfig()
config.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
try await client.setServeConfig(config)
```

Building a ``ServeConfig`` from scratch and writing it would silently delete
every handler somebody else configured. The snapshot-mutate-write pattern —
plus the ETag check below — is what makes writes safe.

## Optimistic concurrency with ETags

``TailscaleClient/serveConfig()`` captures the daemon's `Etag` response
header into ``ServeConfig/etag``, and ``TailscaleClient/setServeConfig(_:)``
replays it as `If-Match`. If anything else modified the config in between
(the Tailscale CLI, another app), the daemon answers HTTP 412 and the client
throws ``TailscaleClientError/preconditionFailed(body:endpoint:)``.

The recovery is always the same — re-fetch, re-apply, retry:

```swift
func addForward(port: UInt16, to target: String, client: TailscaleClient) async throws {
  for _ in 0..<3 {
    var config = try await client.serveConfig()
    config.tcp[port] = TCPPortHandler(tcpForward: target)
    do {
      try await client.setServeConfig(config)
      return
    } catch TailscaleClientError.preconditionFailed {
      continue  // Someone else won the race; rebase on their change.
    }
  }
  throw CancellationError()  // repeatedly outpaced — give up loudly
}
```

An empty ``ServeConfig/etag`` writes unconditionally (matching Tailscale's
own client); reserve that for tooling that intentionally owns the whole
config.

## Funnel

``ServeConfig/allowFunnel`` maps `"host:port"` to whether that listener is
exposed to the **public internet**. Treat any write that flips a value to
`true` as a security decision, and check
``TailscaleClient/queryFeature(_:)`` (`"funnel"`) first — the control plane
reports whether Funnel is enabled for the tailnet and, if not, the admin
URL where it can be turned on.

## Certificates

``TailscaleClient/certDomains()`` lists the DNS names this node can hold
TLS certificates for (empty unless HTTPS is enabled for the tailnet).
``TailscaleClient/certPair(domain:minValidity:)`` fetches (and splits) the
private key and certificate chain:

```swift
if let domain = try await client.certDomains().first {
  let pair = try await client.certPair(domain: domain)
  // pair.privateKeyPEM, pair.certificatePEM — never log the key.
}
```

Two caveats:
- The **first** fetch for a domain can block for many seconds while the
  daemon completes ACME issuance; use a generous
  ``TailscaleClientConfiguration/requestTimeout``.
- Daemons built without ACME support surface
  ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.

``TailscaleClient/setDNS(name:value:)`` publishes the DNS-01 challenge TXT
record for custom ACME flows. The control plane accepts only
`_acme-challenge.<your MagicDNS name>` and rate-limits requests — cache
issued certificates instead of re-requesting them.

## Topics

### Serve configuration
- ``ServeConfig``
- ``TCPPortHandler``
- ``WebServerConfig``
- ``HTTPHandler``
- ``ServiceConfig``

### Certificates & features
- ``CertPair``
- ``CertKind``
- ``QueryFeatureResponse``
