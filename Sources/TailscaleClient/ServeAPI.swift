// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

// MARK: - Serve, Funnel & Certificates (v0.10.0, 1.0.0)

extension TailscaleClient {
  /// Fetches the daemon's current serve/Funnel configuration as an immutable snapshot.
  ///
  /// The returned snapshot carries the daemon's concurrency token in ``ServeConfigSnapshot/etag``
  /// and timestamp in ``ServeConfigSnapshot/fetchedAt``. Pass this snapshot to
  /// ``setServeConfig(_:matching:)`` or ``updateServeConfig(_:mutate:)`` to perform
  /// safe conditional updates that detect concurrent modifications.
  ///
  /// ```swift
  /// let snapshot = try await client.serveConfigSnapshot()
  /// var config = snapshot.config
  /// config.tcp[8080] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
  /// let newSnapshot = try await client.setServeConfig(config, matching: snapshot)
  /// ```
  ///
  /// - Throws:
  ///   - ``TailscaleClientError/missingConcurrencyToken`` if the daemon does not return a valid ETag header.
  ///   - ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)`` if the response is not 200 OK.
  ///   - ``TailscaleClientError/decoding(_:body:endpoint:)`` if the body cannot be decoded.
  public func serveConfigSnapshot() async throws -> ServeConfigSnapshot {
    let endpoint = "/localapi/v0/serve-config"
    let request = TailscaleRequest(method: "GET", path: endpoint)
    let response = try await executeWithDeadline(request, endpoint: endpoint)
    if let error = Self.commonStatusError(response, endpoint: endpoint) {
      throw error
    }
    guard response.statusCode == 200 else {
      throw TailscaleClientError.unexpectedStatus(
        code: response.statusCode, body: response.data, endpoint: endpoint)
    }

    // The daemon serves `null` (or nothing) when no config was ever set.
    var config: ServeConfig
    let trimmed = String(decoding: response.data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "null" {
      config = ServeConfig()
    } else {
      do {
        config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: response.data)
      } catch let decodingError as DecodingError {
        throw TailscaleClientError.decoding(
          decodingError, body: response.data, endpoint: endpoint)
      }
    }

    // The unix transport lowercases header names; URLSession preserves them.
    let etagHeader = response.headers.first { key, _ in
      key.caseInsensitiveCompare("Etag") == .orderedSame
    }
    guard let etag = etagHeader?.value,
      !etag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw TailscaleClientError.missingConcurrencyToken
    }
    return ServeConfigSnapshot(etag: etag, fetchedAt: Date(), config: config)
  }

  /// Safely replaces the daemon's serve/Funnel configuration, matching the provided snapshot's ETag.
  ///
  /// Sends the snapshot's ``ServeConfigSnapshot/etag`` as the `If-Match` HTTP header.
  /// If the configuration has changed on the daemon since the snapshot was fetched,
  /// the write fails with ``TailscaleClientError/preconditionFailed(body:endpoint:)``
  /// without modifying state.
  ///
  /// - Parameters:
  ///   - newConfig: The desired new serve configuration.
  ///   - snapshot: The snapshot against which this update is applied.
  /// - Returns: A fresh ``ServeConfigSnapshot`` representing the updated state and new ETag.
  /// - Throws:
  ///   - ``TailscaleClientError/missingConcurrencyToken`` if `snapshot.etag` is empty.
  ///   - ``TailscaleClientError/preconditionFailed(body:endpoint:)`` if a concurrent edit occurred (HTTP 412).
  ///   - ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)`` on unexpected HTTP statuses.
  public func setServeConfig(
    _ newConfig: ServeConfig,
    matching snapshot: ServeConfigSnapshot
  ) async throws -> ServeConfigSnapshot {
    guard !snapshot.etag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TailscaleClientError.missingConcurrencyToken
    }

    let endpoint = "/localapi/v0/serve-config"
    let body = try JSONEncoder().encode(newConfig)
    let request = TailscaleRequest(
      method: "POST",
      path: endpoint,
      body: body,
      additionalHeaders: ["If-Match": snapshot.etag])
    let response = try await executeWithDeadline(request, endpoint: endpoint)
    if let error = Self.commonStatusError(response, endpoint: endpoint) {
      throw error
    }
    guard (200..<300).contains(response.statusCode) else {
      throw TailscaleClientError.unexpectedStatus(
        code: response.statusCode, body: response.data, endpoint: endpoint)
    }

    let etagHeader = response.headers.first { key, _ in
      key.caseInsensitiveCompare("Etag") == .orderedSame
    }
    if let newEtag = etagHeader?.value,
      !newEtag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return ServeConfigSnapshot(etag: newEtag, fetchedAt: Date(), config: newConfig)
    } else {
      return try await serveConfigSnapshot()
    }
  }

  /// Convenience mutation helper for reading, modifying, and conditionally writing ServeConfig.
  ///
  /// Clones the configuration from `snapshot`, applies the synchronous `mutate` closure,
  /// and writes back the modified configuration matching the snapshot's ETag.
  ///
  /// ```swift
  /// let updated = try await client.updateServeConfig(snapshot) { config in
  ///   config.tcp[8080] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - snapshot: The snapshot to base the update upon.
  ///   - mutate: A closure mutating the working copy of `ServeConfig`.
  /// - Returns: A fresh ``ServeConfigSnapshot`` with the new configuration and new ETag.
  /// - Throws: Any error thrown by `mutate`, or ``TailscaleClientError/preconditionFailed(body:endpoint:)``
  ///   if the daemon configuration was changed concurrently.
  public func updateServeConfig(
    _ snapshot: ServeConfigSnapshot,
    mutate: (inout ServeConfig) throws -> Void
  ) async throws -> ServeConfigSnapshot {
    var config = snapshot.config
    try mutate(&config)
    return try await setServeConfig(config, matching: snapshot)
  }

  /// Unconditionally replaces the daemon's serve/Funnel configuration without concurrency checks.
  ///
  /// > Warning: This replaces the daemon's entire background serve configuration and
  /// > overwrites any concurrent edits made by other processes, CLI commands, or GUIs.
  /// > Use this only for initial setup or explicit force-resets.
  ///
  /// Wraps `POST /localapi/v0/serve-config` with an empty `If-Match` header.
  ///
  /// - Parameter config: The new serve configuration to write.
  /// - Throws: ``TailscaleClientError`` on communication or daemon error.
  public func replaceServeConfigUnconditionally(_ config: ServeConfig) async throws {
    let endpoint = "/localapi/v0/serve-config"
    let body = try JSONEncoder().encode(config)
    let request = TailscaleRequest(
      method: "POST",
      path: endpoint,
      body: body,
      additionalHeaders: ["If-Match": ""])
    _ = try await performRawRequest(request, endpoint: endpoint)
  }

  /// Fetches the daemon's current serve/Funnel configuration.
  ///
  /// - Warning: Deprecated in 1.0. Use ``serveConfigSnapshot()`` instead to ensure safe concurrency.
  @available(*, deprecated, message: "Use serveConfigSnapshot() instead")
  public func serveConfig() async throws -> ServeConfig {
    let snapshot = try await serveConfigSnapshot()
    var config = snapshot.config
    config.etag = snapshot.etag
    return config
  }

  /// Replaces the daemon's serve/Funnel configuration.
  ///
  /// - Warning: Deprecated in 1.0. Use ``setServeConfig(_:matching:)`` for safe conditional updates,
  ///   or ``replaceServeConfigUnconditionally(_:)`` for explicit unconditional replacement.
  @available(
    *, deprecated,
    message: "Use setServeConfig(_:matching:) or replaceServeConfigUnconditionally(_:) instead"
  )
  public func setServeConfig(_ config: ServeConfig) async throws {
    let endpoint = "/localapi/v0/serve-config"
    let body = try JSONEncoder().encode(config)
    let request = TailscaleRequest(
      method: "POST",
      path: endpoint,
      body: body,
      additionalHeaders: ["If-Match": config.etag ?? ""])
    _ = try await performRawRequest(request, endpoint: endpoint)
  }

  /// The DNS names this node can obtain TLS certificates for, sorted
  /// ascending. Empty when HTTPS is not enabled for the tailnet.
  ///
  /// Wraps `GET /localapi/v0/cert-domains`. Daemons built without ACME
  /// support don't register the endpoint (404 on tailscaled 1.96.x
  /// tarball builds, seen live) and surface as
  /// ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.
  public func certDomains() async throws -> [String] {
    let endpoint = "/localapi/v0/cert-domains"
    let request = TailscaleRequest(method: "GET", path: endpoint)
    // Go serializes a nil slice as JSON `null` when the tailnet has no
    // cert domains (seen live against headscale tailnets).
    let domains: [String]? = try await performRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "acme")
    return domains ?? []
  }

  /// Fetches raw PEM bytes for a domain's TLS credential.
  ///
  /// The daemon returns a cached certificate when still valid, otherwise it
  /// synchronously obtains one via ACME — the first call for a domain can
  /// take many seconds, so consider a generous `requestTimeout`.
  ///
  /// Wraps `GET /localapi/v0/cert/<domain>`. Requires the daemon to be
  /// built with ACME support and HTTPS enabled for the tailnet; daemons
  /// without it surface ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.
  ///
  /// - Parameters:
  ///   - domain: A name from ``certDomains()``.
  ///   - kind: Which PEM blocks to return (defaults to the key+cert pair).
  ///   - minValidity: If set, the daemon renews first unless the cert stays
  ///     valid at least this long. Values beyond the ACME provider's maximum
  ///     lifetime are rejected by the daemon.
  public func certPEM(
    domain: String, kind: CertKind = .pair, minValidity: Duration? = nil
  ) async throws -> Data {
    let endpoint = "/localapi/v0/cert/\(domain)"
    var queryItems = [URLQueryItem(name: "type", value: kind.rawValue)]
    if let minValidity {
      queryItems.append(
        URLQueryItem(name: "min_validity", value: "\(minValidity.components.seconds)s"))
    }
    let request = TailscaleRequest(method: "GET", path: endpoint, queryItems: queryItems)
    let response = try await executeWithDeadline(request, endpoint: endpoint)
    if let error = Self.commonStatusError(
      response, endpoint: endpoint, optionalEndpoint: true, feature: "acme")
    {
      throw error
    }
    guard response.statusCode == 200 else {
      throw TailscaleClientError.unexpectedStatus(
        code: response.statusCode, body: response.data, endpoint: endpoint)
    }
    return response.data
  }

  /// Fetches and splits a domain's private key and certificate chain.
  ///
  /// See ``certPEM(domain:kind:minValidity:)`` for latency and availability
  /// caveats.
  public func certPair(domain: String, minValidity: Duration? = nil) async throws -> CertPair {
    let endpoint = "/localapi/v0/cert/\(domain)"
    let data = try await certPEM(domain: domain, kind: .pair, minValidity: minValidity)
    // The pair response is one private-key PEM block followed by the cert
    // blocks; upstream splits at the "--\n--" boundary between them.
    let text = String(decoding: data, as: UTF8.self)
    guard let boundary = text.range(of: "--\n--") else {
      throw TailscaleClientError.unexpectedStatus(code: 200, body: data, endpoint: endpoint)
    }
    let keyEnd = text.index(boundary.lowerBound, offsetBy: 3)  // keep "--\n"
    return CertPair(
      certificatePEM: String(text[keyEnd...]),
      privateKeyPEM: String(text[..<keyEnd]))
  }

  /// Publishes a DNS TXT record for an ACME `dns-01` challenge.
  ///
  /// The control plane only accepts very specific names — effectively
  /// `_acme-challenge.<this node's MagicDNS name>` — and rate-limits these
  /// requests, so cache issued certificates rather than re-requesting.
  ///
  /// Wraps `POST /localapi/v0/set-dns`.
  public func setDNS(name: String, value: String) async throws {
    let endpoint = "/localapi/v0/set-dns"
    let request = TailscaleRequest(
      method: "POST",
      path: endpoint,
      queryItems: [
        URLQueryItem(name: "name", value: name),
        URLQueryItem(name: "value", value: value),
      ])
    _ = try await performRawRequest(request, endpoint: endpoint)
  }

  /// Asks the control plane whether a gated feature (e.g. `"serve"`,
  /// `"funnel"`) is enabled for this node, and how to enable it if not.
  ///
  /// Wraps `POST /localapi/v0/query-feature`. Fails with a 503 status when
  /// the daemon has no netmap yet (logged out).
  public func queryFeature(_ feature: String) async throws -> QueryFeatureResponse {
    let endpoint = "/localapi/v0/query-feature"
    let request = TailscaleRequest(
      method: "POST",
      path: endpoint,
      queryItems: [URLQueryItem(name: "feature", value: feature)])
    return try await performRequest(request, endpoint: endpoint)
  }
}
