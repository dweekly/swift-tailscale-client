// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// A saved login profile (one account/tailnet pairing), from the
/// `profiles/` endpoints.
///
/// Upstream: `ipn.LoginProfile`.
public struct LoginProfile: Codable, Sendable, Equatable {
  /// Stable profile identifier used to switch or delete.
  public var id: String

  /// The profile's login name (e.g., an email address).
  public var name: String

  /// Tailnet-level naming for display.
  public var networkProfile: NetworkProfile?

  /// The user this profile authenticates as.
  public var userProfile: UserProfile?

  /// Stable node ID of this profile's node.
  public var nodeID: String?

  /// Control plane URL (differs for headscale or custom coordination).
  public var controlURL: String?

  /// When the profile was created, when reported.
  public var created: Date?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    id: String,
    name: String = "",
    networkProfile: NetworkProfile? = nil,
    userProfile: UserProfile? = nil,
    nodeID: String? = nil,
    controlURL: String? = nil,
    created: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.networkProfile = networkProfile
    self.userProfile = userProfile
    self.nodeID = nodeID
    self.controlURL = controlURL
    self.created = created
  }

  private enum CodingKeys: String, CodingKey {
    case id = "ID"
    case name = "Name"
    case networkProfile = "NetworkProfile"
    case userProfile = "UserProfile"
    case nodeID = "NodeID"
    case controlURL = "ControlURL"
    case created = "Created"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    networkProfile = try container.decodeIfPresent(NetworkProfile.self, forKey: .networkProfile)
    userProfile = try container.decodeIfPresent(UserProfile.self, forKey: .userProfile)
    nodeID = try container.decodeIfPresent(String.self, forKey: .nodeID)
    controlURL = try container.decodeIfPresent(String.self, forKey: .controlURL)
    created = try container.decodeTailscaleDateIfPresent(forKey: .created)
  }
}

/// Tailnet naming attached to a ``LoginProfile``.
///
/// Upstream: `ipn.NetworkProfile`.
public struct NetworkProfile: Codable, Sendable, Equatable {
  /// The node's MagicDNS name in this tailnet.
  public var magicDNSName: String?

  /// The tailnet's domain name.
  public var domainName: String?

  /// Human-friendly tailnet display name, when set.
  public var displayName: String?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    magicDNSName: String? = nil, domainName: String? = nil, displayName: String? = nil
  ) {
    self.magicDNSName = magicDNSName
    self.domainName = domainName
    self.displayName = displayName
  }

  private enum CodingKeys: String, CodingKey {
    case magicDNSName = "MagicDNSName"
    case domainName = "DomainName"
    case displayName = "DisplayName"
  }
}
