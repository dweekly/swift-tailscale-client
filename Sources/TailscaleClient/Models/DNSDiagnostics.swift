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
