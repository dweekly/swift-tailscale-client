// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// The operating system's effective DNS configuration as tailscaled sees it,
/// from `GET /localapi/v0/dns-osconfig`.
///
/// Useful for diagnosing "DNS works everywhere but here" complaints: it shows
/// which nameservers, search domains, and match (split-DNS) domains Tailscale
/// has installed on the host.
///
/// Upstream: `apitype.DNSOSConfig`.
public struct DNSOSConfig: Codable, Sendable, Equatable {
  /// Resolver addresses currently installed in the OS configuration.
  public var nameservers: [String]

  /// DNS search domains appended to bare hostnames.
  public var searchDomains: [String]

  /// Split-DNS match domains routed to Tailscale's resolver.
  public var matchDomains: [String]

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    nameservers: [String] = [],
    searchDomains: [String] = [],
    matchDomains: [String] = []
  ) {
    self.nameservers = nameservers
    self.searchDomains = searchDomains
    self.matchDomains = matchDomains
  }

  private enum CodingKeys: String, CodingKey {
    case nameservers = "Nameservers"
    case searchDomains = "SearchDomains"
    case matchDomains = "MatchDomains"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    nameservers = try container.decodeIfPresent([String].self, forKey: .nameservers) ?? []
    searchDomains = try container.decodeIfPresent([String].self, forKey: .searchDomains) ?? []
    matchDomains = try container.decodeIfPresent([String].self, forKey: .matchDomains) ?? []
  }
}

/// The result of a DNS query performed through tailscaled's internal
/// forwarder, from `GET /localapi/v0/dns-query`.
///
/// Upstream: `apitype.DNSQueryResponse`.
public struct DNSQueryResponse: Codable, Sendable, Equatable {
  /// The raw DNS response message (RFC 1035 wire format). Feed it to a DNS
  /// message parser to inspect individual records.
  public var bytes: Data

  /// The resolvers the forwarder would use for this query.
  public var resolvers: [DNSResolver]

  /// Creates an instance for tests, previews, or fixtures.
  public init(bytes: Data = Data(), resolvers: [DNSResolver] = []) {
    self.bytes = bytes
    self.resolvers = resolvers
  }

  private enum CodingKeys: String, CodingKey {
    case bytes = "Bytes"
    case resolvers = "Resolvers"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Go serializes []byte as base64; Data's Codable conformance matches.
    bytes = try container.decodeIfPresent(Data.self, forKey: .bytes) ?? Data()
    resolvers = try container.decodeIfPresent([DNSResolver].self, forKey: .resolvers) ?? []
  }
}

/// A DNS resolver known to tailscaled.
///
/// Upstream: `dnstype.Resolver`.
public struct DNSResolver: Codable, Sendable, Equatable {
  /// The resolver's address: a plain IP, an `ip:port`, or a DoH/DoHoW URL
  /// (`https://…` / `http://…`).
  public var address: String?

  /// Suggested IP resolutions for a DoH resolver whose URL is not an IP
  /// literal; empty means "resolve it with classic DNS".
  public var bootstrapResolution: [String]

  /// Whether this resolver stays in use even while an exit node handles
  /// other DNS traffic (split-DNS with exit nodes).
  public var useWithExitNode: Bool

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    address: String? = nil,
    bootstrapResolution: [String] = [],
    useWithExitNode: Bool = false
  ) {
    self.address = address
    self.bootstrapResolution = bootstrapResolution
    self.useWithExitNode = useWithExitNode
  }

  private enum CodingKeys: String, CodingKey {
    case address = "Addr"
    case bootstrapResolution = "BootstrapResolution"
    case useWithExitNode = "UseWithExitNode"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    address = try container.decodeIfPresent(String.self, forKey: .address)
    bootstrapResolution =
      try container.decodeIfPresent([String].self, forKey: .bootstrapResolution) ?? []
    useWithExitNode = try container.decodeIfPresent(Bool.self, forKey: .useWithExitNode) ?? false
  }
}

/// The tailnet's DNS configuration from the current netmap, from
/// `GET /localapi/v0/dns-config` — what the control plane *wants* DNS to be,
/// as opposed to ``DNSOSConfig`` (what is installed on the OS).
///
/// Upstream: a tolerant **subset** of `tailcfg.DNSConfig` — rarely-used
/// upstream fields not modeled here are ignored on decode, never fatal.
public struct DNSConfig: Codable, Sendable, Equatable {
  /// Global resolvers to use when not proxying through quad-100.
  public var resolvers: [DNSResolver]

  /// Split-DNS routes: domain suffix → resolvers for that suffix.
  public var routes: [String: [DNSResolver]]

  /// Resolvers to fall back to when `resolvers` is empty.
  public var fallbackResolvers: [DNSResolver]

  /// Search domains to add to the OS configuration.
  public var domains: [String]

  /// Whether MagicDNS proxying (100.100.100.100) is enabled.
  public var proxied: Bool

  /// Domains for which the daemon obtains TLS certificates.
  public var certDomains: [String]

  /// Extra DNS records the tailnet defines.
  public var extraRecords: [DNSRecord]

  /// DNS names the exit node's DNS proxy must not answer. An entry with a
  /// leading dot (`.example.com`) is a suffix match; any other entry is an
  /// exact match.
  public var exitNodeFilteredSet: [String]

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    resolvers: [DNSResolver] = [],
    routes: [String: [DNSResolver]] = [:],
    fallbackResolvers: [DNSResolver] = [],
    domains: [String] = [],
    proxied: Bool = false,
    certDomains: [String] = [],
    extraRecords: [DNSRecord] = [],
    exitNodeFilteredSet: [String] = []
  ) {
    self.resolvers = resolvers
    self.routes = routes
    self.fallbackResolvers = fallbackResolvers
    self.domains = domains
    self.proxied = proxied
    self.certDomains = certDomains
    self.extraRecords = extraRecords
    self.exitNodeFilteredSet = exitNodeFilteredSet
  }

  private enum CodingKeys: String, CodingKey {
    case resolvers = "Resolvers"
    case routes = "Routes"
    case fallbackResolvers = "FallbackResolvers"
    case domains = "Domains"
    case proxied = "Proxied"
    case certDomains = "CertDomains"
    case extraRecords = "ExtraRecords"
    case exitNodeFilteredSet = "ExitNodeFilteredSet"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    resolvers = try container.decodeIfPresent([DNSResolver].self, forKey: .resolvers) ?? []
    // Go emits nil slices as JSON null for route values (seen live).
    let rawRoutes =
      try container.decodeIfPresent([String: [DNSResolver]?].self, forKey: .routes) ?? [:]
    routes = rawRoutes.mapValues { $0 ?? [] }
    fallbackResolvers =
      try container.decodeIfPresent([DNSResolver].self, forKey: .fallbackResolvers) ?? []
    domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
    proxied = try container.decodeIfPresent(Bool.self, forKey: .proxied) ?? false
    certDomains = try container.decodeIfPresent([String].self, forKey: .certDomains) ?? []
    extraRecords = try container.decodeIfPresent([DNSRecord].self, forKey: .extraRecords) ?? []
    exitNodeFilteredSet =
      try container.decodeIfPresent([String].self, forKey: .exitNodeFilteredSet) ?? []
  }
}

/// One extra DNS record defined by the tailnet.
///
/// Upstream: `tailcfg.DNSRecord`.
public struct DNSRecord: Codable, Sendable, Equatable {
  /// Fully-qualified record name.
  public var name: String

  /// Record type (empty means A/AAAA inferred from the value).
  public var type: String?

  /// The record value (e.g., an IP address).
  public var value: String?

  /// Creates an instance for tests, previews, or fixtures.
  public init(name: String, type: String? = nil, value: String? = nil) {
    self.name = name
    self.type = type
    self.value = value
  }

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case type = "Type"
    case value = "Value"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    type = try container.decodeIfPresent(String.self, forKey: .type)
    value = try container.decodeIfPresent(String.self, forKey: .value)
  }
}

/// The subnet-router preflight result from `GET /localapi/v0/check-ip-forwarding`.
///
/// An empty warning means IP forwarding is configured correctly for
/// advertising routes or being an exit node.
public struct IPForwardingCheck: Codable, Sendable, Equatable {
  /// Human-readable problem description, or `nil`/empty when all is well.
  public var warning: String?

  /// Whether the host is ready to forward traffic (no warning reported).
  public var isReady: Bool { warning?.isEmpty ?? true }

  /// Creates an instance for tests, previews, or fixtures.
  public init(warning: String? = nil) {
    self.warning = warning
  }

  private enum CodingKeys: String, CodingKey {
    case warning = "Warning"
  }
}
