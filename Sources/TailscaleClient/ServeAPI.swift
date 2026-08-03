// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

// MARK: - Serve, Funnel & Certificates (v0.10.0)

extension TailscaleClient {
  /// Fetches the daemon's current serve/Funnel configuration.
  ///
  /// The returned config carries the daemon's concurrency token in
  /// ``ServeConfig/etag``; keep it and pass the modified config to
  /// ``setServeConfig(_:)`` so concurrent writers are detected instead of
  /// silently overwritten.
  ///
  /// ```swift
  /// var config = try await client.serveConfig()
  /// config.tcp[8080] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
  /// try await client.setServeConfig(config)  // 412 if it changed meanwhile
  /// ```
  public func serveConfig() async throws -> ServeConfig {
    let endpoint = "/localapi/v0/serve-config"
    let request = TailscaleRequest(method: "GET", path: endpoint)
    let response = try await executeWithDeadline(request, endpoint: endpoint)
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
    config.etag = response.headers.first { $0.key.caseInsensitiveCompare("Etag") == .orderedSame }?
      .value
    return config
  }

  /// Replaces the daemon's serve/Funnel configuration.
  ///
  /// Sends the config's ``ServeConfig/etag`` as `If-Match`: if the daemon's
  /// configuration changed since that ETag was fetched, the write fails with
  /// ``TailscaleClientError/preconditionFailed(body:endpoint:)`` — re-fetch
  /// via ``serveConfig()``, re-apply your change, and retry. An empty/`nil`
  /// `etag` writes unconditionally (matching upstream's client behavior).
  ///
  /// > Warning: This replaces the whole background configuration. Always
  /// > start from a fresh ``serveConfig()`` snapshot rather than
  /// > constructing one from scratch, or you will drop existing handlers.
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
  /// Wraps `GET /localapi/v0/cert-domains`.
  public func certDomains() async throws -> [String] {
    let endpoint = "/localapi/v0/cert-domains"
    let request = TailscaleRequest(method: "GET", path: endpoint)
    return try await performRequest(request, endpoint: endpoint)
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
    if response.statusCode == 404 || response.statusCode == 501 {
      throw TailscaleClientError.endpointUnavailable(endpoint: endpoint, feature: "acme")
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
