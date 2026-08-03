// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Represents the payload returned from `/localapi/v0/status`.
public struct StatusResponse: Sendable, Codable, Equatable {
  public let version: String?
  public let isTunEnabled: Bool?
  public let backendState: BackendState?
  public let haveNodeKey: Bool?
  public let authURL: URL?
  public let tailscaleIPs: [String]
  public let selfNode: NodeStatus?
  public let peers: [String: NodeStatus]
  public let users: [String: UserProfile]
  public let magicDNSSuffix: String?
  public let currentTailnet: TailnetStatus?
  public let certDomains: [String]
  public let clientVersion: ClientVersionStatus?
  public let health: [String]

  /// The network interface used by Tailscale (e.g., "utun16").
  ///
  /// This property discovers the TUN interface by matching `tailscaleIPs` against
  /// the system's network interfaces. Returns `nil` if no matching interface is found
  /// or if the platform doesn't support interface enumeration.
  ///
  /// Example:
  /// ```swift
  /// let status = try await client.status()
  /// if let iface = status.interfaceName {
  ///     print("Tailscale interface: \(iface)")  // e.g., "utun16"
  /// }
  /// ```
  public var interfaceName: String? {
    NetworkInterfaceDiscovery.tailscaleInterface(matching: tailscaleIPs)?.name
  }

  /// Full interface information for the Tailscale TUN interface.
  ///
  /// Provides additional details beyond just the name, including whether the
  /// interface is up, running, and its type (point-to-point for TUN).
  public var interfaceInfo: NetworkInterfaceDiscovery.InterfaceInfo? {
    NetworkInterfaceDiscovery.tailscaleInterface(matching: tailscaleIPs)
  }

  public init(
    version: String? = nil,
    isTunEnabled: Bool? = nil,
    backendState: BackendState? = nil,
    haveNodeKey: Bool? = nil,
    authURL: URL? = nil,
    tailscaleIPs: [String] = [],
    selfNode: NodeStatus? = nil,
    peers: [String: NodeStatus] = [:],
    users: [String: UserProfile] = [:],
    magicDNSSuffix: String? = nil,
    currentTailnet: TailnetStatus? = nil,
    certDomains: [String] = [],
    clientVersion: ClientVersionStatus? = nil,
    health: [String] = []
  ) {
    self.version = version
    self.isTunEnabled = isTunEnabled
    self.backendState = backendState
    self.haveNodeKey = haveNodeKey
    self.authURL = authURL
    self.tailscaleIPs = tailscaleIPs
    self.selfNode = selfNode
    self.peers = peers
    self.users = users
    self.magicDNSSuffix = magicDNSSuffix
    self.currentTailnet = currentTailnet
    self.certDomains = certDomains
    self.clientVersion = clientVersion
    self.health = health
  }

  enum CodingKeys: String, CodingKey {
    case version = "Version"
    case isTunEnabled = "TUN"
    case backendState = "BackendState"
    case haveNodeKey = "HaveNodeKey"
    case authURL = "AuthURL"
    case tailscaleIPs = "TailscaleIPs"
    case selfNode = "Self"
    case peers = "Peer"
    case users = "User"
    case magicDNSSuffix = "MagicDNSSuffix"
    case currentTailnet = "CurrentTailnet"
    case certDomains = "CertDomains"
    case clientVersion = "ClientVersion"
    case health = "Health"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(String.self, forKey: .version)
    isTunEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTunEnabled)
    backendState = try container.decodeIfPresent(BackendState.self, forKey: .backendState)
    haveNodeKey = try container.decodeIfPresent(Bool.self, forKey: .haveNodeKey)

    if let rawAuthURL = try container.decodeIfPresent(String.self, forKey: .authURL),
      !rawAuthURL.isEmpty
    {
      authURL = URL(string: rawAuthURL)
    } else {
      authURL = nil
    }

    tailscaleIPs = try container.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
    selfNode = try container.decodeIfPresent(NodeStatus.self, forKey: .selfNode)
    peers = try container.decodeIfPresent([String: NodeStatus].self, forKey: .peers) ?? [:]
    users = try container.decodeIfPresent([String: UserProfile].self, forKey: .users) ?? [:]
    magicDNSSuffix = try container.decodeIfPresent(String.self, forKey: .magicDNSSuffix)
    currentTailnet = try container.decodeIfPresent(TailnetStatus.self, forKey: .currentTailnet)
    certDomains = try container.decodeIfPresent([String].self, forKey: .certDomains) ?? []
    clientVersion = try container.decodeIfPresent(ClientVersionStatus.self, forKey: .clientVersion)
    health = try container.decodeIfPresent([String].self, forKey: .health) ?? []
  }
}

public enum BackendState: String, Sendable, Codable {
  case running = "Running"
  case stopped = "Stopped"
  case needsLogin = "NeedsLogin"
  case starting = "Starting"
  case other

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    if let known = BackendState(rawValue: rawValue) {
      self = known
    } else {
      self = .other
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .other:
      try container.encode("Other")
    default:
      try container.encode(rawValue)
    }
  }
}

public struct NodeStatus: Sendable, Codable, Equatable {
  public let id: String
  public let publicKey: String
  public let hostName: String
  public let dnsName: String
  public let operatingSystem: String?
  public let userID: UInt64?
  public let tailscaleIPs: [String]
  public let allowedIPs: [String]
  public let addresses: [String]?
  public let currentAddress: String?
  public let relay: String?
  public let peerRelay: String?
  public let rxBytes: UInt64?
  public let txBytes: UInt64?
  public let created: Date?
  public let lastWrite: Date?
  public let lastSeen: Date?
  public let lastHandshake: Date?
  public let online: Bool?
  public let exitNode: Bool?
  public let exitNodeOption: Bool?
  public let active: Bool?
  public let peerAPIURL: [URL]?
  public let taildropTarget: Int?
  public let noFileSharingReason: String?
  public let capabilities: [String]?
  public let capabilityMap: [String: CapabilityValue]?
  public let inNetworkMap: Bool?
  public let inMagicSock: Bool?
  public let inEngine: Bool?
  public let expired: Bool?
  public let keyExpiry: Date?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    id: String,
    publicKey: String,
    hostName: String,
    dnsName: String,
    operatingSystem: String? = nil,
    userID: UInt64? = nil,
    tailscaleIPs: [String] = [],
    allowedIPs: [String] = [],
    addresses: [String]? = nil,
    currentAddress: String? = nil,
    relay: String? = nil,
    peerRelay: String? = nil,
    rxBytes: UInt64? = nil,
    txBytes: UInt64? = nil,
    created: Date? = nil,
    lastWrite: Date? = nil,
    lastSeen: Date? = nil,
    lastHandshake: Date? = nil,
    online: Bool? = nil,
    exitNode: Bool? = nil,
    exitNodeOption: Bool? = nil,
    active: Bool? = nil,
    peerAPIURL: [URL]? = nil,
    taildropTarget: Int? = nil,
    noFileSharingReason: String? = nil,
    capabilities: [String]? = nil,
    capabilityMap: [String: CapabilityValue]? = nil,
    inNetworkMap: Bool? = nil,
    inMagicSock: Bool? = nil,
    inEngine: Bool? = nil,
    expired: Bool? = nil,
    keyExpiry: Date? = nil
  ) {
    self.id = id
    self.publicKey = publicKey
    self.hostName = hostName
    self.dnsName = dnsName
    self.operatingSystem = operatingSystem
    self.userID = userID
    self.tailscaleIPs = tailscaleIPs
    self.allowedIPs = allowedIPs
    self.addresses = addresses
    self.currentAddress = currentAddress
    self.relay = relay
    self.peerRelay = peerRelay
    self.rxBytes = rxBytes
    self.txBytes = txBytes
    self.created = created
    self.lastWrite = lastWrite
    self.lastSeen = lastSeen
    self.lastHandshake = lastHandshake
    self.online = online
    self.exitNode = exitNode
    self.exitNodeOption = exitNodeOption
    self.active = active
    self.peerAPIURL = peerAPIURL
    self.taildropTarget = taildropTarget
    self.noFileSharingReason = noFileSharingReason
    self.capabilities = capabilities
    self.capabilityMap = capabilityMap
    self.inNetworkMap = inNetworkMap
    self.inMagicSock = inMagicSock
    self.inEngine = inEngine
    self.expired = expired
    self.keyExpiry = keyExpiry
  }

  enum CodingKeys: String, CodingKey {
    case id = "ID"
    case publicKey = "PublicKey"
    case hostName = "HostName"
    case dnsName = "DNSName"
    case operatingSystem = "OS"
    case userID = "UserID"
    case tailscaleIPs = "TailscaleIPs"
    case allowedIPs = "AllowedIPs"
    case addresses = "Addrs"
    case currentAddress = "CurAddr"
    case relay = "Relay"
    case peerRelay = "PeerRelay"
    case rxBytes = "RxBytes"
    case txBytes = "TxBytes"
    case created = "Created"
    case lastWrite = "LastWrite"
    case lastSeen = "LastSeen"
    case lastHandshake = "LastHandshake"
    case online = "Online"
    case exitNode = "ExitNode"
    case exitNodeOption = "ExitNodeOption"
    case active = "Active"
    case peerAPIURL = "PeerAPIURL"
    case taildropTarget = "TaildropTarget"
    case noFileSharingReason = "NoFileSharingReason"
    case capabilities = "Capabilities"
    case capabilityMap = "CapMap"
    case inNetworkMap = "InNetworkMap"
    case inMagicSock = "InMagicSock"
    case inEngine = "InEngine"
    case expired = "Expired"
    case keyExpiry = "KeyExpiry"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    publicKey = try container.decode(String.self, forKey: .publicKey)
    hostName = try container.decode(String.self, forKey: .hostName)
    dnsName = try container.decode(String.self, forKey: .dnsName)
    operatingSystem = try container.decodeIfPresent(String.self, forKey: .operatingSystem)
    userID = try container.decodeIfPresent(UInt64.self, forKey: .userID)
    tailscaleIPs = try container.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
    allowedIPs = try container.decodeIfPresent([String].self, forKey: .allowedIPs) ?? []
    addresses = try container.decodeIfPresent([String].self, forKey: .addresses)
    currentAddress = try container.decodeIfPresent(String.self, forKey: .currentAddress)
    relay = try container.decodeIfPresent(String.self, forKey: .relay)
    peerRelay = try container.decodeIfPresent(String.self, forKey: .peerRelay)
    rxBytes = try container.decodeIfPresent(UInt64.self, forKey: .rxBytes)
    txBytes = try container.decodeIfPresent(UInt64.self, forKey: .txBytes)
    created = try container.decodeTailscaleDateIfPresent(forKey: .created)
    lastWrite = try container.decodeTailscaleDateIfPresent(forKey: .lastWrite)
    lastSeen = try container.decodeTailscaleDateIfPresent(forKey: .lastSeen)
    lastHandshake = try container.decodeTailscaleDateIfPresent(forKey: .lastHandshake)
    online = try container.decodeIfPresent(Bool.self, forKey: .online)
    exitNode = try container.decodeIfPresent(Bool.self, forKey: .exitNode)
    exitNodeOption = try container.decodeIfPresent(Bool.self, forKey: .exitNodeOption)
    active = try container.decodeIfPresent(Bool.self, forKey: .active)

    if let urls = try container.decodeIfPresent([String].self, forKey: .peerAPIURL) {
      let parsed = urls.compactMap { URL(string: $0) }
      peerAPIURL = parsed.isEmpty ? nil : parsed
    } else {
      peerAPIURL = nil
    }

    taildropTarget = try container.decodeIfPresent(Int.self, forKey: .taildropTarget)
    noFileSharingReason = try container.decodeIfPresent(String.self, forKey: .noFileSharingReason)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
    capabilityMap = try container.decodeIfPresent(
      [String: CapabilityValue].self, forKey: .capabilityMap)
    inNetworkMap = try container.decodeIfPresent(Bool.self, forKey: .inNetworkMap)
    inMagicSock = try container.decodeIfPresent(Bool.self, forKey: .inMagicSock)
    inEngine = try container.decodeIfPresent(Bool.self, forKey: .inEngine)
    expired = try container.decodeIfPresent(Bool.self, forKey: .expired)
    keyExpiry = try container.decodeTailscaleDateIfPresent(forKey: .keyExpiry)
  }
}

/// The value of one entry in a node's capability map (`CapMap`).
///
/// Upstream (`tailcfg.NodeCapMap`) each value is either `null` or an array of
/// arbitrary JSON. Homogeneous arrays of the common scalar types decode into
/// the typed cases; anything else (booleans mixed with strings, objects, etc.)
/// decodes into ``raw(_:)`` so that unfamiliar capability values never cause
/// a status or whois response to fail decoding.
public enum CapabilityValue: Sendable, Codable, Equatable {
  case null
  case integers([Int])
  case strings([String])
  case booleans([Bool])
  /// An array of values that is not uniformly integers, strings, or booleans.
  case raw([JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let integers = try? container.decode([Int].self) {
      self = .integers(integers)
      return
    }
    if let strings = try? container.decode([String].self) {
      self = .strings(strings)
      return
    }
    if let booleans = try? container.decode([Bool].self) {
      self = .booleans(booleans)
      return
    }
    if let values = try? container.decode([JSONValue].self) {
      self = .raw(values)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "Capability value is not null or a JSON array")
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .integers(let values):
      try container.encode(values)
    case .strings(let values):
      try container.encode(values)
    case .booleans(let values):
      try container.encode(values)
    case .raw(let values):
      try container.encode(values)
    }
  }
}

public struct TailnetStatus: Sendable, Codable, Equatable {
  public let name: String?
  public let magicDNSSuffix: String?
  public let magicDNSEnabled: Bool?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    name: String? = nil,
    magicDNSSuffix: String? = nil,
    magicDNSEnabled: Bool? = nil
  ) {
    self.name = name
    self.magicDNSSuffix = magicDNSSuffix
    self.magicDNSEnabled = magicDNSEnabled
  }

  enum CodingKeys: String, CodingKey {
    case name = "Name"
    case magicDNSSuffix = "MagicDNSSuffix"
    case magicDNSEnabled = "MagicDNSEnabled"
  }
}

public struct UserProfile: Sendable, Codable, Equatable {
  public let id: UInt64
  public let loginName: String?
  public let displayName: String?
  public let profilePicURL: URL?
  /// SCIM/policy groups the user belongs to, when the tailnet uses them.
  public let groups: [String]

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    id: UInt64,
    loginName: String? = nil,
    displayName: String? = nil,
    profilePicURL: URL? = nil,
    groups: [String] = []
  ) {
    self.id = id
    self.loginName = loginName
    self.displayName = displayName
    self.profilePicURL = profilePicURL
    self.groups = groups
  }

  enum CodingKeys: String, CodingKey {
    case id = "ID"
    case loginName = "LoginName"
    case displayName = "DisplayName"
    case profilePicURL = "ProfilePicURL"
    case groups = "Groups"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UInt64.self, forKey: .id)
    loginName = try container.decodeIfPresent(String.self, forKey: .loginName)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    if let rawURL = try container.decodeIfPresent(String.self, forKey: .profilePicURL),
      !rawURL.isEmpty
    {
      profilePicURL = URL(string: rawURL)
    } else {
      profilePicURL = nil
    }
    groups = try container.decodeIfPresent([String].self, forKey: .groups) ?? []
  }
}

public struct ClientVersionStatus: Sendable, Codable, Equatable {
  /// Whether the client is running the latest build. Upstream marks every
  /// boolean here `omitempty`, so `false` is simply absent on the wire —
  /// absence decodes as `false`, never as "unknown".
  public let runningLatest: Bool

  /// Latest available client version, when the daemon knows one.
  public let latestVersion: String?

  /// Whether the available update carries an urgent security fix.
  public let urgentSecurityUpdate: Bool

  /// Whether the daemon suggests notifying the user about the update.
  public let notify: Bool

  /// URL to show the user alongside an update notification.
  public let notifyURL: String?

  /// Text to show the user alongside an update notification.
  public let notifyText: String?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    runningLatest: Bool = false,
    latestVersion: String? = nil,
    urgentSecurityUpdate: Bool = false,
    notify: Bool = false,
    notifyURL: String? = nil,
    notifyText: String? = nil
  ) {
    self.runningLatest = runningLatest
    self.latestVersion = latestVersion
    self.urgentSecurityUpdate = urgentSecurityUpdate
    self.notify = notify
    self.notifyURL = notifyURL
    self.notifyText = notifyText
  }

  enum CodingKeys: String, CodingKey {
    case runningLatest = "RunningLatest"
    case latestVersion = "LatestVersion"
    case urgentSecurityUpdate = "UrgentSecurityUpdate"
    case notify = "Notify"
    case notifyURL = "NotifyURL"
    case notifyText = "NotifyText"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    runningLatest = try container.decodeIfPresent(Bool.self, forKey: .runningLatest) ?? false
    latestVersion = try container.decodeIfPresent(String.self, forKey: .latestVersion)
    urgentSecurityUpdate =
      try container.decodeIfPresent(Bool.self, forKey: .urgentSecurityUpdate) ?? false
    notify = try container.decodeIfPresent(Bool.self, forKey: .notify) ?? false
    notifyURL = try container.decodeIfPresent(String.self, forKey: .notifyURL)
    notifyText = try container.decodeIfPresent(String.self, forKey: .notifyText)
  }
}
