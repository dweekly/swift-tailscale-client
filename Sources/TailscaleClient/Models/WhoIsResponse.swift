// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Represents the payload returned from `/localapi/v0/whois`.
///
/// This endpoint identifies who is at a given Tailscale IP address or node key,
/// returning both node information and user profile details.
public struct WhoIsResponse: Sendable, Codable, Equatable {
  /// The node associated with the queried IP or key.
  public let node: WhoIsNode?
  /// The user profile that owns the node.
  public let userProfile: UserProfile?
  /// Peer capabilities map (capability URL to optional values).
  public let capMap: [String: CapabilityValue]?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    node: WhoIsNode? = nil,
    userProfile: UserProfile? = nil,
    capMap: [String: CapabilityValue]? = nil
  ) {
    self.node = node
    self.userProfile = userProfile
    self.capMap = capMap
  }

  enum CodingKeys: String, CodingKey {
    case node = "Node"
    case userProfile = "UserProfile"
    case capMap = "CapMap"
  }
}

/// Node information returned by the whois endpoint.
///
/// This is similar to `NodeStatus` from the status endpoint but may contain
/// additional fields specific to the whois response.
public struct WhoIsNode: Sendable, Codable, Equatable {
  /// Unique node identifier.
  public let id: UInt64
  /// Stable node identifier that persists across key rotations.
  public let stableID: String?
  /// Node name (may include domain suffix).
  public let name: String?
  /// User ID that owns this node.
  public let user: UInt64?
  /// Node's public key.
  public let key: String?
  /// Key expiration time.
  public let keyExpiry: Date?
  /// Machine public key.
  public let machine: String?
  /// Disco key for peer-to-peer discovery.
  public let discoKey: String?
  /// Tailscale IP addresses assigned to this node.
  public let addresses: [String]
  /// IP ranges this node is allowed to route.
  public let allowedIPs: [String]
  /// Network endpoints (IP:port) where this node can be reached.
  public let endpoints: [String]
  /// Legacy DERP endpoint string ("127.3.3.40:<region>").
  public let derp: String?

  /// Home DERP region ID (replaces the legacy `derp` string upstream).
  public let homeDERP: Int?
  /// Host information (OS, hostname, etc.).
  public let hostinfo: WhoIsHostinfo?
  /// When the node was created.
  public let created: Date?
  /// Tags applied to this node.
  public let tags: [String]
  /// Whether the node's key has expired.
  public let expired: Bool?
  /// Whether the node is online.
  public let online: Bool?
  /// When the node was last seen.
  public let lastSeen: Date?
  /// Computed display name for the node.
  public let computedName: String?
  /// Computed name including hostname.
  public let computedNameWithHost: String?
  /// Whether this node is an exit node.
  public let isExitNode: Bool?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    id: UInt64,
    stableID: String? = nil,
    name: String? = nil,
    user: UInt64? = nil,
    key: String? = nil,
    keyExpiry: Date? = nil,
    machine: String? = nil,
    discoKey: String? = nil,
    addresses: [String] = [],
    allowedIPs: [String] = [],
    endpoints: [String] = [],
    derp: String? = nil,
    homeDERP: Int? = nil,
    hostinfo: WhoIsHostinfo? = nil,
    created: Date? = nil,
    tags: [String] = [],
    expired: Bool? = nil,
    online: Bool? = nil,
    lastSeen: Date? = nil,
    computedName: String? = nil,
    computedNameWithHost: String? = nil,
    isExitNode: Bool? = nil
  ) {
    self.id = id
    self.stableID = stableID
    self.name = name
    self.user = user
    self.key = key
    self.keyExpiry = keyExpiry
    self.machine = machine
    self.discoKey = discoKey
    self.addresses = addresses
    self.allowedIPs = allowedIPs
    self.endpoints = endpoints
    self.derp = derp
    self.homeDERP = homeDERP
    self.hostinfo = hostinfo
    self.created = created
    self.tags = tags
    self.expired = expired
    self.online = online
    self.lastSeen = lastSeen
    self.computedName = computedName
    self.computedNameWithHost = computedNameWithHost
    self.isExitNode = isExitNode
  }

  enum CodingKeys: String, CodingKey {
    case id = "ID"
    case stableID = "StableID"
    case name = "Name"
    case user = "User"
    case key = "Key"
    case keyExpiry = "KeyExpiry"
    case machine = "Machine"
    case discoKey = "DiscoKey"
    case addresses = "Addresses"
    case allowedIPs = "AllowedIPs"
    case endpoints = "Endpoints"
    case derp = "DERP"
    case homeDERP = "HomeDERP"
    case hostinfo = "Hostinfo"
    case created = "Created"
    case tags = "Tags"
    case expired = "Expired"
    case online = "Online"
    case lastSeen = "LastSeen"
    case computedName = "ComputedName"
    case computedNameWithHost = "ComputedNameWithHost"
    case isExitNode = "IsExitNode"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UInt64.self, forKey: .id)
    stableID = try container.decodeIfPresent(String.self, forKey: .stableID)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    user = try container.decodeIfPresent(UInt64.self, forKey: .user)
    key = try container.decodeIfPresent(String.self, forKey: .key)
    keyExpiry = try container.decodeTailscaleDateIfPresent(forKey: .keyExpiry)
    machine = try container.decodeIfPresent(String.self, forKey: .machine)
    discoKey = try container.decodeIfPresent(String.self, forKey: .discoKey)
    addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
    allowedIPs = try container.decodeIfPresent([String].self, forKey: .allowedIPs) ?? []
    endpoints = try container.decodeIfPresent([String].self, forKey: .endpoints) ?? []
    derp = try container.decodeIfPresent(String.self, forKey: .derp)
    homeDERP = try container.decodeIfPresent(Int.self, forKey: .homeDERP)
    hostinfo = try container.decodeIfPresent(WhoIsHostinfo.self, forKey: .hostinfo)
    created = try container.decodeTailscaleDateIfPresent(forKey: .created)
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    expired = try container.decodeIfPresent(Bool.self, forKey: .expired)
    online = try container.decodeIfPresent(Bool.self, forKey: .online)
    lastSeen = try container.decodeTailscaleDateIfPresent(forKey: .lastSeen)
    computedName = try container.decodeIfPresent(String.self, forKey: .computedName)
    computedNameWithHost = try container.decodeIfPresent(String.self, forKey: .computedNameWithHost)
    isExitNode = try container.decodeIfPresent(Bool.self, forKey: .isExitNode)
  }
}

/// Host information for a node.
public struct WhoIsHostinfo: Sendable, Codable, Equatable {
  /// Operating system (e.g., "darwin", "linux", "windows").
  public let os: String?
  /// OS version string.
  public let osVersion: String?
  /// Hostname of the machine.
  public let hostname: String?
  /// Device model (e.g., "MacBookPro18,3").
  public let deviceModel: String?
  /// Tailscale client version.
  public let tailscaleVersion: String?
  /// Whether this is a Tailscale SSH server.
  public let isSSHServer: Bool?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    os: String? = nil,
    osVersion: String? = nil,
    hostname: String? = nil,
    deviceModel: String? = nil,
    tailscaleVersion: String? = nil,
    isSSHServer: Bool? = nil
  ) {
    self.os = os
    self.osVersion = osVersion
    self.hostname = hostname
    self.deviceModel = deviceModel
    self.tailscaleVersion = tailscaleVersion
    self.isSSHServer = isSSHServer
  }

  enum CodingKeys: String, CodingKey {
    case os = "OS"
    case osVersion = "OSVersion"
    case hostname = "Hostname"
    case deviceModel = "DeviceModel"
    case tailscaleVersion = "TailscaleVersion"
    case isSSHServer = "SSH"
  }
}
