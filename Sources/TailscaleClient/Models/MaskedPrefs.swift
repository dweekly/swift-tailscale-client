// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// A partial preferences update for ``TailscaleClient/editPrefs(_:)``.
///
/// The LocalAPI's `PATCH /localapi/v0/prefs` takes an `ipn.MaskedPrefs`: each
/// preference value travels with a matching `<Name>Set` flag so the daemon
/// knows which fields to apply and which to leave untouched. This type makes
/// that contract impossible to get wrong — set a property and both the value
/// and its mask flag are encoded; leave it `nil` and neither is.
///
/// ```swift
/// var change = MaskedPrefs()
/// change.exitNodeID = "nExitNodeStable123"
/// change.exitNodeAllowLANAccess = true
/// let updated = try await client.editPrefs(change)
/// ```
///
/// Only the commonly-adjusted preferences are exposed; niche or dangerous
/// fields (control URL, netfilter mode, profile switches) stay out of the
/// typed surface deliberately.
public struct MaskedPrefs: Sendable, Equatable {
  /// Route all traffic through the exit node (`--exit-node` semantics).
  public var routeAll: Bool?

  /// Stable node ID of the exit node to use; empty string clears it.
  public var exitNodeID: String?

  /// Tailscale IP of the exit node to use; empty string clears it.
  public var exitNodeIP: String?

  /// Keep direct LAN access while an exit node is active.
  public var exitNodeAllowLANAccess: Bool?

  /// Use Tailscale DNS settings (MagicDNS).
  public var corpDNS: Bool?

  /// Run the Tailscale SSH server.
  public var runSSH: Bool?

  /// Run the Tailscale web client.
  public var runWebClient: Bool?

  /// Whether the backend should be running (connect/disconnect).
  public var wantRunning: Bool?

  /// Block all incoming connections.
  public var shieldsUp: Bool?

  /// ACL tags to advertise for this node.
  public var advertiseTags: [String]?

  /// Hostname override for this node.
  public var hostname: String?

  /// Subnet routes to advertise (CIDR strings).
  public var advertiseRoutes: [String]?

  /// Disable source-NAT for advertised routes (Linux subnet routers).
  public var noSNAT: Bool?

  /// Local user allowed to operate tailscaled without root.
  public var operatorUser: String?

  /// Enable posture checking.
  public var postureChecking: Bool?

  /// Automatically check for updates.
  public var autoUpdateCheck: Bool?

  /// Automatically apply updates.
  public var autoUpdateApply: Bool?

  /// Creates an empty update; set only the fields you want to change.
  public init() {}

  /// Whether no fields have been set (the daemon would apply nothing).
  public var isEmpty: Bool {
    routeAll == nil && exitNodeID == nil && exitNodeIP == nil
      && exitNodeAllowLANAccess == nil && corpDNS == nil && runSSH == nil
      && runWebClient == nil && wantRunning == nil && shieldsUp == nil
      && advertiseTags == nil && hostname == nil && advertiseRoutes == nil
      && noSNAT == nil && operatorUser == nil && postureChecking == nil
      && autoUpdateCheck == nil && autoUpdateApply == nil
  }
}

extension MaskedPrefs: Encodable {
  private struct WireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { self.stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: WireKey.self)

    func put<T: Encodable>(_ value: T?, _ name: String) throws {
      guard let value else { return }
      try container.encode(value, forKey: WireKey(name))
      try container.encode(true, forKey: WireKey(name + "Set"))
    }

    try put(routeAll, "RouteAll")
    try put(exitNodeID, "ExitNodeID")
    try put(exitNodeIP, "ExitNodeIP")
    try put(exitNodeAllowLANAccess, "ExitNodeAllowLANAccess")
    try put(corpDNS, "CorpDNS")
    try put(runSSH, "RunSSH")
    try put(runWebClient, "RunWebClient")
    try put(wantRunning, "WantRunning")
    try put(shieldsUp, "ShieldsUp")
    try put(advertiseTags, "AdvertiseTags")
    try put(hostname, "Hostname")
    try put(advertiseRoutes, "AdvertiseRoutes")
    try put(noSNAT, "NoSNAT")
    try put(operatorUser, "OperatorUser")
    try put(postureChecking, "PostureChecking")

    // AutoUpdate travels as a nested value + nested mask.
    if autoUpdateCheck != nil || autoUpdateApply != nil {
      var value = container.nestedContainer(keyedBy: WireKey.self, forKey: WireKey("AutoUpdate"))
      var mask = container.nestedContainer(keyedBy: WireKey.self, forKey: WireKey("AutoUpdateSet"))
      if let check = autoUpdateCheck {
        try value.encode(check, forKey: WireKey("Check"))
        try mask.encode(true, forKey: WireKey("CheckSet"))
      }
      if let apply = autoUpdateApply {
        try value.encode(apply, forKey: WireKey("Apply"))
        try mask.encode(true, forKey: WireKey("ApplySet"))
      }
    }
  }
}
