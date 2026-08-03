// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// The daemon's serve/Funnel configuration, from
/// `GET /localapi/v0/serve-config`.
///
/// Mirrors upstream `ipn.ServeConfig` as a tolerant subset: unknown fields
/// are ignored on decode, never fatal. Map keys follow upstream conventions —
/// `tcp` is keyed by port, `web` and `allowFunnel` by `"host:port"` (the
/// port is always explicit), and `foreground` by daemon-assigned session ID.
///
/// ### Optimistic concurrency
/// ``TailscaleClient/serveConfig()`` stores the daemon's `Etag` response
/// header into ``etag``. Pass the same instance (or at least the same
/// ``etag``) to ``TailscaleClient/setServeConfig(_:)`` and the daemon
/// rejects the write with HTTP 412
/// (``TailscaleClientError/preconditionFailed(body:endpoint:)``) if the
/// configuration changed underneath you — re-fetch, re-apply, retry.
public struct ServeConfig: Codable, Sendable, Equatable {
  /// TCP forwarding handlers, keyed by listening port.
  public var tcp: [UInt16: TCPPortHandler]

  /// Web (HTTP/HTTPS) handlers, keyed by `"host:port"`.
  public var web: [String: WebServerConfig]

  /// Tailscale Services configuration, keyed by service name
  /// (e.g. `"svc:name"`).
  public var services: [String: ServiceConfig]

  /// Which `"host:port"` listeners may be exposed to the public internet
  /// via Funnel.
  public var allowFunnel: [String: Bool]

  /// Foreground (session-scoped) serve configs, keyed by daemon session ID.
  /// These vanish when their owning session disconnects.
  public var foreground: [String: ServeConfig]

  /// Opaque concurrency token from the daemon's `Etag` response header.
  /// Not part of the JSON body — populated by
  /// ``TailscaleClient/serveConfig()`` and sent back as `If-Match` by
  /// ``TailscaleClient/setServeConfig(_:)``. Empty/`nil` writes
  /// unconditionally.
  public var etag: String?

  /// Whether no serving is configured at all.
  public var isEmpty: Bool {
    tcp.isEmpty && web.isEmpty && services.isEmpty && allowFunnel.isEmpty && foreground.isEmpty
  }

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    tcp: [UInt16: TCPPortHandler] = [:],
    web: [String: WebServerConfig] = [:],
    services: [String: ServiceConfig] = [:],
    allowFunnel: [String: Bool] = [:],
    foreground: [String: ServeConfig] = [:],
    etag: String? = nil
  ) {
    self.tcp = tcp
    self.web = web
    self.services = services
    self.allowFunnel = allowFunnel
    self.foreground = foreground
    self.etag = etag
  }

  private enum CodingKeys: String, CodingKey {
    case tcp = "TCP"
    case web = "Web"
    case services = "Services"
    case allowFunnel = "AllowFunnel"
    case foreground = "Foreground"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Go serializes the uint16-keyed TCP map with string object keys;
    // Swift's [UInt16:] Codable would use a flat array, so map by hand.
    let rawTCP = try container.decodeIfPresent([String: TCPPortHandler].self, forKey: .tcp) ?? [:]
    tcp = rawTCP.reduce(into: [:]) { result, entry in
      if let port = UInt16(entry.key) { result[port] = entry.value }
    }
    web = try container.decodeIfPresent([String: WebServerConfig].self, forKey: .web) ?? [:]
    services = try container.decodeIfPresent([String: ServiceConfig].self, forKey: .services) ?? [:]
    allowFunnel = try container.decodeIfPresent([String: Bool].self, forKey: .allowFunnel) ?? [:]
    foreground =
      try container.decodeIfPresent([String: ServeConfig].self, forKey: .foreground) ?? [:]
    etag = nil
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    // Match upstream omitempty: absent maps, not empty objects; etag is
    // carried in HTTP headers, never in the body.
    if !tcp.isEmpty {
      let rawTCP = tcp.reduce(into: [String: TCPPortHandler]()) { $0[String($1.key)] = $1.value }
      try container.encode(rawTCP, forKey: .tcp)
    }
    if !web.isEmpty { try container.encode(web, forKey: .web) }
    if !services.isEmpty { try container.encode(services, forKey: .services) }
    if !allowFunnel.isEmpty { try container.encode(allowFunnel, forKey: .allowFunnel) }
    if !foreground.isEmpty { try container.encode(foreground, forKey: .foreground) }
  }
}

/// A TCP handler on one serve port.
///
/// Exactly one mode is populated: `https`/`http` (terminate and hand to the
/// web handlers) or `tcpForward` (raw forwarding, optionally with
/// `terminateTLS`).
///
/// Upstream: `ipn.TCPPortHandler`.
public struct TCPPortHandler: Codable, Sendable, Equatable {
  /// Terminate TLS and route as HTTPS to the matching `web` handlers.
  public var https: Bool

  /// Plain HTTP to the matching `web` handlers.
  public var http: Bool

  /// Forward raw TCP to this `"ip:port"` destination.
  public var tcpForward: String?

  /// If forwarding, terminate TLS first using the cert for this SNI name.
  public var terminateTLS: String?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    https: Bool = false,
    http: Bool = false,
    tcpForward: String? = nil,
    terminateTLS: String? = nil
  ) {
    self.https = https
    self.http = http
    self.tcpForward = tcpForward
    self.terminateTLS = terminateTLS
  }

  private enum CodingKeys: String, CodingKey {
    case https = "HTTPS"
    case http = "HTTP"
    case tcpForward = "TCPForward"
    case terminateTLS = "TerminateTLS"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    https = try container.decodeIfPresent(Bool.self, forKey: .https) ?? false
    http = try container.decodeIfPresent(Bool.self, forKey: .http) ?? false
    tcpForward = try container.decodeIfPresent(String.self, forKey: .tcpForward)
    terminateTLS = try container.decodeIfPresent(String.self, forKey: .terminateTLS)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if https { try container.encode(true, forKey: .https) }
    if http { try container.encode(true, forKey: .http) }
    try container.encodeIfPresent(tcpForward, forKey: .tcpForward)
    try container.encodeIfPresent(terminateTLS, forKey: .terminateTLS)
  }
}

/// The HTTP handlers behind one `"host:port"` web listener, keyed by
/// mount point (e.g. `"/"`, `"/api"`).
///
/// Upstream: `ipn.WebServerConfig`.
public struct WebServerConfig: Codable, Sendable, Equatable {
  /// Mount point → handler.
  public var handlers: [String: HTTPHandler]

  /// Creates an instance for tests, previews, or fixtures.
  public init(handlers: [String: HTTPHandler] = [:]) {
    self.handlers = handlers
  }

  private enum CodingKeys: String, CodingKey {
    case handlers = "Handlers"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    handlers = try container.decodeIfPresent([String: HTTPHandler].self, forKey: .handlers) ?? [:]
  }
}

/// One HTTP request handler: exactly one of `path`, `proxy`, `text`, or
/// `redirect` is set.
///
/// Upstream: `ipn.HTTPHandler`.
public struct HTTPHandler: Codable, Sendable, Equatable {
  /// Serve files (or a single file) from this absolute directory path.
  public var path: String?

  /// Reverse-proxy to this URL or `host:port`.
  public var proxy: String?

  /// Serve this fixed text (200 OK).
  public var text: String?

  /// Redirect (308) to this URL.
  public var redirect: String?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    path: String? = nil,
    proxy: String? = nil,
    text: String? = nil,
    redirect: String? = nil
  ) {
    self.path = path
    self.proxy = proxy
    self.text = text
    self.redirect = redirect
  }

  private enum CodingKeys: String, CodingKey {
    case path = "Path"
    case proxy = "Proxy"
    case text = "Text"
    case redirect = "Redirect"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decodeIfPresent(String.self, forKey: .path)
    proxy = try container.decodeIfPresent(String.self, forKey: .proxy)
    text = try container.decodeIfPresent(String.self, forKey: .text)
    redirect = try container.decodeIfPresent(String.self, forKey: .redirect)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(path, forKey: .path)
    try container.encodeIfPresent(proxy, forKey: .proxy)
    try container.encodeIfPresent(text, forKey: .text)
    try container.encodeIfPresent(redirect, forKey: .redirect)
  }
}

/// Serve configuration for one Tailscale Service.
///
/// Upstream: `ipn.ServiceConfig`.
public struct ServiceConfig: Codable, Sendable, Equatable {
  /// TCP forwarding handlers, keyed by listening port.
  public var tcp: [UInt16: TCPPortHandler]

  /// Web handlers, keyed by `"host:port"`.
  public var web: [String: WebServerConfig]

  /// Whether the service is in TUN (L3) mode; mutually exclusive with
  /// `tcp`/`web`.
  public var tun: Bool

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    tcp: [UInt16: TCPPortHandler] = [:],
    web: [String: WebServerConfig] = [:],
    tun: Bool = false
  ) {
    self.tcp = tcp
    self.web = web
    self.tun = tun
  }

  private enum CodingKeys: String, CodingKey {
    case tcp = "TCP"
    case web = "Web"
    case tun = "Tun"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawTCP = try container.decodeIfPresent([String: TCPPortHandler].self, forKey: .tcp) ?? [:]
    tcp = rawTCP.reduce(into: [:]) { result, entry in
      if let port = UInt16(entry.key) { result[port] = entry.value }
    }
    web = try container.decodeIfPresent([String: WebServerConfig].self, forKey: .web) ?? [:]
    tun = try container.decodeIfPresent(Bool.self, forKey: .tun) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if !tcp.isEmpty {
      let rawTCP = tcp.reduce(into: [String: TCPPortHandler]()) { $0[String($1.key)] = $1.value }
      try container.encode(rawTCP, forKey: .tcp)
    }
    if !web.isEmpty { try container.encode(web, forKey: .web) }
    if tun { try container.encode(true, forKey: .tun) }
  }
}
