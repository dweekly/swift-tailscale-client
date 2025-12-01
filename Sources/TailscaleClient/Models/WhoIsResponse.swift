// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Represents the payload returned from `/localapi/v0/whois`.
///
/// This endpoint identifies who is at a given Tailscale IP address or node key,
/// returning both node information and user profile details.
public struct WhoIsResponse: Sendable, Decodable {
  /// The node associated with the queried IP or key.
  public let node: WhoIsNode?
  /// The user profile that owns the node.
  public let userProfile: UserProfile?
  /// Peer capabilities map (capability URL to optional values).
  public let capMap: [String: CapabilityValue]?

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
public struct WhoIsNode: Sendable, Decodable {
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
  /// Preferred DERP region ID.
  public let derp: String?
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
public struct WhoIsHostinfo: Sendable, Decodable {
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

  enum CodingKeys: String, CodingKey {
    case os = "OS"
    case osVersion = "OSVersion"
    case hostname = "Hostname"
    case deviceModel = "DeviceModel"
    case tailscaleVersion = "TailscaleVersion"
    case isSSHServer = "SSH"
  }
}
