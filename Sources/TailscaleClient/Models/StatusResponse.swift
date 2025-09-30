// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly


import Foundation

/// Represents the payload returned from `/localapi/v0/status`.
public struct StatusResponse: Sendable, Decodable {
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

public enum BackendState: String, Sendable, Decodable {
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

public struct NodeStatus: Sendable, Decodable {
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

public enum CapabilityValue: Sendable, Decodable {
  case null
  case integers([Int])
  case strings([String])

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
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "Unsupported capability value")
  }
}

public struct TailnetStatus: Sendable, Decodable {
  public let name: String?
  public let magicDNSSuffix: String?
  public let magicDNSEnabled: Bool?

  enum CodingKeys: String, CodingKey {
    case name = "Name"
    case magicDNSSuffix = "MagicDNSSuffix"
    case magicDNSEnabled = "MagicDNSEnabled"
  }
}

public struct UserProfile: Sendable, Decodable {
  public let id: UInt64
  public let loginName: String?
  public let displayName: String?
  public let profilePicURL: URL?

  enum CodingKeys: String, CodingKey {
    case id = "ID"
    case loginName = "LoginName"
    case displayName = "DisplayName"
    case profilePicURL = "ProfilePicURL"
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
  }
}

public struct ClientVersionStatus: Sendable, Decodable {
  public let runningLatest: Bool?

  enum CodingKeys: String, CodingKey {
    case runningLatest = "RunningLatest"
  }
}

extension KeyedDecodingContainer where K: CodingKey {
  fileprivate func decodeTailscaleDateIfPresent(forKey key: K) throws -> Date? {
    guard let isoString = try decodeIfPresent(String.self, forKey: key) else {
      return nil
    }
    return TailscaleDateParser.parse(isoString)
  }
}
