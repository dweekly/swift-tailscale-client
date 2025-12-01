// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Represents the preferences returned from `/localapi/v0/prefs`.
///
/// This contains the current Tailscale configuration settings for this node.
public struct Prefs: Sendable, Decodable {
  /// The control server URL (usually https://controlplane.tailscale.com).
  public let controlURL: String?

  /// Whether to route all traffic through Tailscale (full tunnel mode).
  public let routeAll: Bool?

  /// Stable ID of the exit node being used.
  public let exitNodeID: String?

  /// IP address of the exit node being used.
  public let exitNodeIP: String?

  /// Whether to allow LAN access when using an exit node.
  public let exitNodeAllowLANAccess: Bool?

  /// Whether to use Tailscale's DNS (MagicDNS).
  public let corpDNS: Bool?

  /// Whether Tailscale SSH server is enabled.
  public let runSSH: Bool?

  /// Whether the web client is enabled.
  public let runWebClient: Bool?

  /// Whether Tailscale should be running (user's intent).
  public let wantRunning: Bool?

  /// Whether the user has logged out.
  public let loggedOut: Bool?

  /// Whether shields-up mode is enabled (block incoming connections).
  public let shieldsUp: Bool?

  /// ACL tags to advertise for this node.
  public let advertiseTags: [String]

  /// Custom hostname for this node.
  public let hostname: String?

  /// Whether to force daemon mode.
  public let forceDaemon: Bool?

  /// Subnet routes this node advertises.
  public let advertiseRoutes: [String]

  /// Whether SNAT is disabled.
  public let noSNAT: Bool?

  /// Netfilter mode on Linux.
  public let netfilterMode: Int?

  /// Unix username that can operate Tailscale without sudo.
  public let operatorUser: String?

  /// Name of the current profile.
  public let profileName: String?

  /// Auto-update preferences.
  public let autoUpdate: AutoUpdatePrefs?

  /// App connector preferences.
  public let appConnector: AppConnectorPrefs?

  /// Whether posture checking is enabled.
  public let postureChecking: Bool?

  enum CodingKeys: String, CodingKey {
    case controlURL = "ControlURL"
    case routeAll = "RouteAll"
    case exitNodeID = "ExitNodeID"
    case exitNodeIP = "ExitNodeIP"
    case exitNodeAllowLANAccess = "ExitNodeAllowLANAccess"
    case corpDNS = "CorpDNS"
    case runSSH = "RunSSH"
    case runWebClient = "RunWebClient"
    case wantRunning = "WantRunning"
    case loggedOut = "LoggedOut"
    case shieldsUp = "ShieldsUp"
    case advertiseTags = "AdvertiseTags"
    case hostname = "Hostname"
    case forceDaemon = "ForceDaemon"
    case advertiseRoutes = "AdvertiseRoutes"
    case noSNAT = "NoSNAT"
    case netfilterMode = "NetfilterMode"
    case operatorUser = "OperatorUser"
    case profileName = "ProfileName"
    case autoUpdate = "AutoUpdate"
    case appConnector = "AppConnector"
    case postureChecking = "PostureChecking"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    controlURL = try container.decodeIfPresent(String.self, forKey: .controlURL)
    routeAll = try container.decodeIfPresent(Bool.self, forKey: .routeAll)
    exitNodeID = try container.decodeIfPresent(String.self, forKey: .exitNodeID)
    exitNodeIP = try container.decodeIfPresent(String.self, forKey: .exitNodeIP)
    exitNodeAllowLANAccess = try container.decodeIfPresent(
      Bool.self, forKey: .exitNodeAllowLANAccess)
    corpDNS = try container.decodeIfPresent(Bool.self, forKey: .corpDNS)
    runSSH = try container.decodeIfPresent(Bool.self, forKey: .runSSH)
    runWebClient = try container.decodeIfPresent(Bool.self, forKey: .runWebClient)
    wantRunning = try container.decodeIfPresent(Bool.self, forKey: .wantRunning)
    loggedOut = try container.decodeIfPresent(Bool.self, forKey: .loggedOut)
    shieldsUp = try container.decodeIfPresent(Bool.self, forKey: .shieldsUp)
    advertiseTags = try container.decodeIfPresent([String].self, forKey: .advertiseTags) ?? []
    hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
    forceDaemon = try container.decodeIfPresent(Bool.self, forKey: .forceDaemon)
    advertiseRoutes = try container.decodeIfPresent([String].self, forKey: .advertiseRoutes) ?? []
    noSNAT = try container.decodeIfPresent(Bool.self, forKey: .noSNAT)
    netfilterMode = try container.decodeIfPresent(Int.self, forKey: .netfilterMode)
    operatorUser = try container.decodeIfPresent(String.self, forKey: .operatorUser)
    profileName = try container.decodeIfPresent(String.self, forKey: .profileName)
    autoUpdate = try container.decodeIfPresent(AutoUpdatePrefs.self, forKey: .autoUpdate)
    appConnector = try container.decodeIfPresent(AppConnectorPrefs.self, forKey: .appConnector)
    postureChecking = try container.decodeIfPresent(Bool.self, forKey: .postureChecking)
  }
}

/// Auto-update preferences.
public struct AutoUpdatePrefs: Sendable, Decodable {
  /// Whether to check for updates automatically.
  public let check: Bool?
  /// Whether to apply updates automatically.
  public let apply: Bool?

  enum CodingKeys: String, CodingKey {
    case check = "Check"
    case apply = "Apply"
  }
}

/// App connector preferences.
public struct AppConnectorPrefs: Sendable, Decodable {
  /// Whether app connector is advertised.
  public let advertise: Bool?

  enum CodingKeys: String, CodingKey {
    case advertise = "Advertise"
  }
}
