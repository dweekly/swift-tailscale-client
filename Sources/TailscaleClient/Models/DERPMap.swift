// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// The DERP relay map the daemon is currently using, from `GET /localapi/v0/derpmap`.
///
/// DERP (Designated Encrypted Relay for Packets) servers relay traffic between
/// peers that cannot connect directly and assist NAT traversal. The map is
/// keyed by region ID; each region contains one or more relay nodes.
///
/// Upstream: `tailcfg.DERPMap`.
public struct DERPMap: Codable, Sendable, Equatable {
  /// Optional client behavior defaults, such as region scoring weights.
  public var homeParams: DERPHomeParams?

  /// DERP regions keyed by region ID.
  public var regions: [Int: DERPRegion]

  /// Whether this map omits the default Tailscale-operated regions on purpose
  /// (as opposed to a partial map that should be merged with the defaults).
  public var omitDefaultRegions: Bool

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    homeParams: DERPHomeParams? = nil,
    regions: [Int: DERPRegion] = [:],
    omitDefaultRegions: Bool = false
  ) {
    self.homeParams = homeParams
    self.regions = regions
    self.omitDefaultRegions = omitDefaultRegions
  }

  /// Regions ordered by ascending region ID, convenient for display.
  public var sortedRegions: [DERPRegion] {
    regions.sorted { $0.key < $1.key }.map(\.value)
  }

  private enum CodingKeys: String, CodingKey {
    case homeParams = "HomeParams"
    case regions = "Regions"
    // Upstream tags this one field lower-camel-case, unlike its siblings.
    case omitDefaultRegions = "omitDefaultRegions"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    homeParams = try container.decodeIfPresent(DERPHomeParams.self, forKey: .homeParams)
    regions = try container.decodeIfPresent([Int: DERPRegion].self, forKey: .regions) ?? [:]
    omitDefaultRegions =
      try container.decodeIfPresent(Bool.self, forKey: .omitDefaultRegions) ?? false
  }
}

/// Client behavior defaults distributed with a ``DERPMap``.
///
/// Upstream: `tailcfg.DERPHomeParams`.
public struct DERPHomeParams: Codable, Sendable, Equatable {
  /// Multipliers (keyed by region ID) applied to measured latency when
  /// choosing a home region. Values below 1 prefer a region; above 1 penalize.
  public var regionScore: [Int: Double]

  /// Creates an instance for tests, previews, or fixtures.
  public init(regionScore: [Int: Double] = [:]) {
    self.regionScore = regionScore
  }

  private enum CodingKeys: String, CodingKey {
    case regionScore = "RegionScore"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    regionScore = try container.decodeIfPresent([Int: Double].self, forKey: .regionScore) ?? [:]
  }
}

/// A geographic region containing one or more DERP relay nodes.
///
/// Upstream: `tailcfg.DERPRegion`.
public struct DERPRegion: Codable, Sendable, Equatable {
  /// Unique region identifier (also this region's key in ``DERPMap/regions``).
  public var regionID: Int

  /// Short region code (e.g., "nyc", "sfo").
  public var regionCode: String

  /// Human-readable region name (e.g., "New York City").
  public var regionName: String

  /// Approximate region latitude in degrees, when published.
  public var latitude: Double?

  /// Approximate region longitude in degrees, when published.
  public var longitude: Double?

  /// Whether clients should avoid this region unless explicitly configured.
  public var avoid: Bool

  /// Whether clients should neither measure latency to nor home in this region.
  public var noMeasureNoHome: Bool

  /// The relay nodes in this region, in priority order.
  public var nodes: [DERPNode]

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    regionID: Int = 0,
    regionCode: String = "",
    regionName: String = "",
    latitude: Double? = nil,
    longitude: Double? = nil,
    avoid: Bool = false,
    noMeasureNoHome: Bool = false,
    nodes: [DERPNode] = []
  ) {
    self.regionID = regionID
    self.regionCode = regionCode
    self.regionName = regionName
    self.latitude = latitude
    self.longitude = longitude
    self.avoid = avoid
    self.noMeasureNoHome = noMeasureNoHome
    self.nodes = nodes
  }

  private enum CodingKeys: String, CodingKey {
    case regionID = "RegionID"
    case regionCode = "RegionCode"
    case regionName = "RegionName"
    case latitude = "Latitude"
    case longitude = "Longitude"
    case avoid = "Avoid"
    case noMeasureNoHome = "NoMeasureNoHome"
    case nodes = "Nodes"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    regionID = try container.decodeIfPresent(Int.self, forKey: .regionID) ?? 0
    regionCode = try container.decodeIfPresent(String.self, forKey: .regionCode) ?? ""
    regionName = try container.decodeIfPresent(String.self, forKey: .regionName) ?? ""
    latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
    longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
    avoid = try container.decodeIfPresent(Bool.self, forKey: .avoid) ?? false
    noMeasureNoHome = try container.decodeIfPresent(Bool.self, forKey: .noMeasureNoHome) ?? false
    nodes = try container.decodeIfPresent([DERPNode].self, forKey: .nodes) ?? []
  }
}

/// A single DERP relay server within a ``DERPRegion``.
///
/// Upstream: `tailcfg.DERPNode`. Port fields use Go zero-value conventions;
/// prefer ``effectiveSTUNPort`` and ``effectiveDERPPort`` over the raw values.
public struct DERPNode: Codable, Sendable, Equatable {
  /// Unique node name, typically hostname-derived (e.g., "1f").
  public var name: String

  /// The ID of the region this node belongs to.
  public var regionID: Int

  /// DNS hostname clients connect to.
  public var hostName: String

  /// TLS certificate hostname, when it differs from ``hostName``.
  public var certName: String?

  /// IPv4 address, when pinned. The literal `"none"` means IPv4 is unsupported.
  public var ipv4: String?

  /// IPv6 address, when pinned. The literal `"none"` means IPv6 is unsupported.
  public var ipv6: String?

  /// Raw STUN port: `0` means the default (3478), `-1` disables STUN.
  /// Prefer ``effectiveSTUNPort``.
  public var stunPort: Int

  /// Whether this node only serves STUN (no DERP relaying).
  public var stunOnly: Bool

  /// Raw DERP port: `0` means the default (443). Prefer ``effectiveDERPPort``.
  public var derpPort: Int

  /// Test-only flag: skips certificate verification. Never set in production maps.
  public var insecureForTests: Bool

  /// Test-only STUN source-IP override. Never set in production maps.
  public var stunTestIP: String?

  /// Whether the node also answers DERP HTTP requests on port 80.
  public var canPort80: Bool

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    name: String = "",
    regionID: Int = 0,
    hostName: String = "",
    certName: String? = nil,
    ipv4: String? = nil,
    ipv6: String? = nil,
    stunPort: Int = 0,
    stunOnly: Bool = false,
    derpPort: Int = 0,
    insecureForTests: Bool = false,
    stunTestIP: String? = nil,
    canPort80: Bool = false
  ) {
    self.name = name
    self.regionID = regionID
    self.hostName = hostName
    self.certName = certName
    self.ipv4 = ipv4
    self.ipv6 = ipv6
    self.stunPort = stunPort
    self.stunOnly = stunOnly
    self.derpPort = derpPort
    self.insecureForTests = insecureForTests
    self.stunTestIP = stunTestIP
    self.canPort80 = canPort80
  }

  /// The UDP port to use for STUN, or `nil` when STUN is disabled on this node.
  public var effectiveSTUNPort: Int? {
    if stunPort < 0 { return nil }
    return stunPort == 0 ? 3478 : stunPort
  }

  /// The TCP port to use for DERP-over-HTTPS.
  public var effectiveDERPPort: Int {
    derpPort == 0 ? 443 : derpPort
  }

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case regionID = "RegionID"
    case hostName = "HostName"
    case certName = "CertName"
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
    case stunPort = "STUNPort"
    case stunOnly = "STUNOnly"
    case derpPort = "DERPPort"
    case insecureForTests = "InsecureForTests"
    case stunTestIP = "STUNTestIP"
    case canPort80 = "CanPort80"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    regionID = try container.decodeIfPresent(Int.self, forKey: .regionID) ?? 0
    hostName = try container.decodeIfPresent(String.self, forKey: .hostName) ?? ""
    certName = try container.decodeIfPresent(String.self, forKey: .certName)
    ipv4 = try container.decodeIfPresent(String.self, forKey: .ipv4)
    ipv6 = try container.decodeIfPresent(String.self, forKey: .ipv6)
    stunPort = try container.decodeIfPresent(Int.self, forKey: .stunPort) ?? 0
    stunOnly = try container.decodeIfPresent(Bool.self, forKey: .stunOnly) ?? false
    derpPort = try container.decodeIfPresent(Int.self, forKey: .derpPort) ?? 0
    insecureForTests =
      try container.decodeIfPresent(Bool.self, forKey: .insecureForTests) ?? false
    stunTestIP = try container.decodeIfPresent(String.self, forKey: .stunTestIP)
    canPort80 = try container.decodeIfPresent(Bool.self, forKey: .canPort80) ?? false
  }
}
