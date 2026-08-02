// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// A notification message from the Tailscale IPN bus.
///
/// Notifications are sparse: most fields will be `nil` unless they've changed.
/// The first message in a session typically contains initial state based on
/// the watch options specified.
///
/// ```swift
/// for try await notify in client.watchIPNBus() {
///     if let state = notify.state {
///         print("State changed to: \(state)")
///     }
///     if let health = notify.health {
///         print("Health warnings: \(health.warnings?.count ?? 0)")
///     }
/// }
/// ```
public struct IPNNotify: Codable, Sendable, Equatable {
  /// Version of the Tailscale backend (first message only).
  public var version: String?

  /// Unique session ID for this watch connection (first message only).
  public var sessionID: String?

  /// Critical error message from the backend.
  public var errMessage: String?

  /// Login process completed successfully.
  public var loginFinished: Bool?

  /// Backend state changed.
  public var state: IPNState?

  /// URL to open in browser (e.g., for OAuth flow).
  public var browseToURL: String?

  /// WireGuard engine statistics.
  public var engine: EngineStatus?

  /// Health state of the backend.
  public var health: HealthState?

  /// Suggested best exit node for current network conditions.
  public var suggestedExitNode: String?

  /// Local TCP port the frontend is listening on.
  public var localTCPPort: UInt16?

  /// Preferences changed (or initial prefs when `.initialPrefs` is requested).
  /// Same shape as `/localapi/v0/prefs`.
  public var prefs: Prefs?

  /// Network map changed (or initial netmap when `.initialNetMap` is requested).
  /// Preserved losslessly as raw JSON; a typed NetworkMap model is planned.
  public var netMap: JSONValue?

  /// Taildrop transfers currently being received.
  public var incomingFiles: [PartialFile]?

  /// Taildrop transfers currently being sent.
  public var outgoingFiles: [OutgoingFile]?

  /// Present when Taildrop files are waiting to be fetched (the payload
  /// itself is an empty marker object).
  public var filesWaiting: EmptyMessage?

  // Note: DriveShares, ClientVersion, and the peer-change patch fields are
  // not modeled yet; unknown keys are ignored by the decoder.

  private enum CodingKeys: String, CodingKey {
    case version = "Version"
    case sessionID = "SessionID"
    case errMessage = "ErrMessage"
    case loginFinished = "LoginFinished"
    case state = "State"
    case browseToURL = "BrowseToURL"
    case engine = "Engine"
    case health = "Health"
    case suggestedExitNode = "SuggestedExitNode"
    case localTCPPort = "LocalTCPPort"
    case prefs = "Prefs"
    case netMap = "NetMap"
    case incomingFiles = "IncomingFiles"
    case outgoingFiles = "OutgoingFiles"
    case filesWaiting = "FilesWaiting"
  }

  public init(
    version: String? = nil,
    sessionID: String? = nil,
    errMessage: String? = nil,
    loginFinished: Bool? = nil,
    state: IPNState? = nil,
    browseToURL: String? = nil,
    engine: EngineStatus? = nil,
    health: HealthState? = nil,
    suggestedExitNode: String? = nil,
    localTCPPort: UInt16? = nil,
    prefs: Prefs? = nil,
    netMap: JSONValue? = nil,
    incomingFiles: [PartialFile]? = nil,
    outgoingFiles: [OutgoingFile]? = nil,
    filesWaiting: EmptyMessage? = nil
  ) {
    self.version = version
    self.sessionID = sessionID
    self.errMessage = errMessage
    self.loginFinished = loginFinished
    self.state = state
    self.browseToURL = browseToURL
    self.engine = engine
    self.health = health
    self.suggestedExitNode = suggestedExitNode
    self.localTCPPort = localTCPPort
    self.prefs = prefs
    self.netMap = netMap
    self.incomingFiles = incomingFiles
    self.outgoingFiles = outgoingFiles
    self.filesWaiting = filesWaiting
  }

  /// Whether the daemon reports Taildrop files waiting to be fetched.
  public var hasFilesWaiting: Bool {
    filesWaiting != nil
  }
}

/// An empty JSON object used upstream as a presence marker (`empty.Message`).
public struct EmptyMessage: Codable, Sendable, Equatable {
  /// Creates an instance for tests, previews, or fixtures.
  public init() {}
}

/// A Taildrop file currently being received (upstream: `ipn.PartialFile`).
public struct PartialFile: Codable, Sendable, Equatable {
  /// File name, e.g. "photo.jpg".
  public var name: String
  /// When the transfer started.
  public var started: Date?
  /// Declared size in bytes, or -1 if unknown.
  public var declaredSize: Int64?
  /// Bytes received so far.
  public var received: Int64?
  /// Whether the transfer finished and the file is ready to be renamed into place.
  public var done: Bool?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    name: String,
    started: Date? = nil,
    declaredSize: Int64? = nil,
    received: Int64? = nil,
    done: Bool? = nil
  ) {
    self.name = name
    self.started = started
    self.declaredSize = declaredSize
    self.received = received
    self.done = done
  }

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case started = "Started"
    case declaredSize = "DeclaredSize"
    case received = "Received"
    case done = "Done"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    started = try container.decodeTailscaleDateIfPresent(forKey: .started)
    declaredSize = try container.decodeIfPresent(Int64.self, forKey: .declaredSize)
    received = try container.decodeIfPresent(Int64.self, forKey: .received)
    done = try container.decodeIfPresent(Bool.self, forKey: .done)
  }
}

/// A Taildrop file currently being sent (upstream: `ipn.OutgoingFile`).
public struct OutgoingFile: Codable, Sendable, Equatable {
  /// Unique transfer identifier.
  public var id: String?
  /// Stable node ID of the receiving peer.
  public var peerID: String?
  /// File name.
  public var name: String?
  /// When the transfer started.
  public var started: Date?
  /// Declared size in bytes.
  public var declaredSize: Int64?
  /// Bytes sent so far.
  public var sent: Int64?
  /// Whether the transfer has finished (successfully or not).
  public var finished: Bool?
  /// Whether a finished transfer succeeded.
  public var succeeded: Bool?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    id: String? = nil,
    peerID: String? = nil,
    name: String? = nil,
    started: Date? = nil,
    declaredSize: Int64? = nil,
    sent: Int64? = nil,
    finished: Bool? = nil,
    succeeded: Bool? = nil
  ) {
    self.id = id
    self.peerID = peerID
    self.name = name
    self.started = started
    self.declaredSize = declaredSize
    self.sent = sent
    self.finished = finished
    self.succeeded = succeeded
  }

  private enum CodingKeys: String, CodingKey {
    case id = "ID"
    case peerID = "PeerID"
    case name = "Name"
    case started = "Started"
    case declaredSize = "DeclaredSize"
    case sent = "Sent"
    case finished = "Finished"
    case succeeded = "Succeeded"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    peerID = try container.decodeIfPresent(String.self, forKey: .peerID)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    started = try container.decodeTailscaleDateIfPresent(forKey: .started)
    declaredSize = try container.decodeIfPresent(Int64.self, forKey: .declaredSize)
    sent = try container.decodeIfPresent(Int64.self, forKey: .sent)
    finished = try container.decodeIfPresent(Bool.self, forKey: .finished)
    succeeded = try container.decodeIfPresent(Bool.self, forKey: .succeeded)
  }
}

/// The state of the Tailscale backend.
public enum IPNState: Int, Codable, Sendable, Equatable, CustomStringConvertible {
  /// No state (initial/unknown).
  case noState = 0
  /// The daemon is in use by another user on this machine.
  case inUseOtherUser = 1
  /// User needs to log in.
  case needsLogin = 2
  /// Waiting for machine authorization from admin.
  case needsMachineAuth = 3
  /// Tailscale is stopped/disconnected.
  case stopped = 4
  /// Tailscale is starting up.
  case starting = 5
  /// Tailscale is running and connected.
  case running = 6

  public var description: String {
    switch self {
    case .noState: return "NoState"
    case .inUseOtherUser: return "InUseOtherUser"
    case .needsLogin: return "NeedsLogin"
    case .needsMachineAuth: return "NeedsMachineAuth"
    case .stopped: return "Stopped"
    case .starting: return "Starting"
    case .running: return "Running"
    }
  }

  /// Whether the backend is in a connected/running state.
  public var isRunning: Bool {
    self == .running
  }

  /// Whether the backend requires user action (login or machine auth).
  public var requiresAction: Bool {
    self == .needsLogin || self == .needsMachineAuth
  }
}

/// WireGuard engine statistics.
public struct EngineStatus: Codable, Sendable, Equatable {
  /// Total bytes received.
  public var rBytes: Int64

  /// Total bytes sent.
  public var wBytes: Int64

  /// Number of live peer connections.
  public var numLive: Int

  /// Number of active DERP relay connections.
  public var liveDERPs: Int

  // Note: LivePeers map omitted for simplicity. Add if needed.

  private enum CodingKeys: String, CodingKey {
    case rBytes = "RBytes"
    case wBytes = "WBytes"
    case numLive = "NumLive"
    case liveDERPs = "LiveDERPs"
  }

  public init(rBytes: Int64 = 0, wBytes: Int64 = 0, numLive: Int = 0, liveDERPs: Int = 0) {
    self.rBytes = rBytes
    self.wBytes = wBytes
    self.numLive = numLive
    self.liveDERPs = liveDERPs
  }
}

/// Health state of the Tailscale backend.
public struct HealthState: Codable, Sendable, Equatable {
  /// Current health warnings, if any.
  public var warnings: [String: HealthWarning]?

  private enum CodingKeys: String, CodingKey {
    case warnings = "Warnings"
  }

  public init(warnings: [String: HealthWarning]? = nil) {
    self.warnings = warnings
  }

  /// Whether there are any active health warnings.
  public var hasWarnings: Bool {
    guard let warnings = warnings else { return false }
    return !warnings.isEmpty
  }
}

/// A single health warning from the backend.
public struct HealthWarning: Codable, Sendable, Equatable {
  /// Unique identifier for this warning type.
  public var warningCode: String?

  /// Severity level of the warning.
  public var severity: String?

  /// Human-readable title.
  public var title: String?

  /// Detailed description of the warning.
  public var text: String?

  /// Whether this warning should break the connection indicator.
  public var impactsConnectivity: Bool?

  private enum CodingKeys: String, CodingKey {
    case warningCode = "WarnableCode"
    case severity = "Severity"
    case title = "Title"
    case text = "Text"
    case impactsConnectivity = "ImpactsConnectivity"
  }

  public init(
    warningCode: String? = nil,
    severity: String? = nil,
    title: String? = nil,
    text: String? = nil,
    impactsConnectivity: Bool? = nil
  ) {
    self.warningCode = warningCode
    self.severity = severity
    self.title = title
    self.text = text
    self.impactsConnectivity = impactsConnectivity
  }
}

/// Options for watching the IPN bus.
///
/// These are bitmask flags that control what notifications are sent
/// and what initial state is included in the first message.
public struct NotifyWatchOpt: OptionSet, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  /// Include periodic engine status updates.
  public static let engineUpdates = NotifyWatchOpt(rawValue: 1 << 0)

  /// Include current state in the first message.
  public static let initialState = NotifyWatchOpt(rawValue: 1 << 1)

  /// Include current preferences in the first message.
  public static let initialPrefs = NotifyWatchOpt(rawValue: 1 << 2)

  /// Include current network map in the first message.
  public static let initialNetMap = NotifyWatchOpt(rawValue: 1 << 3)

  /// Omit private keys from notifications.
  public static let noPrivateKeys = NotifyWatchOpt(rawValue: 1 << 4)

  /// Include Taildrive shares in the first message.
  public static let initialDriveShares = NotifyWatchOpt(rawValue: 1 << 5)

  /// Include outgoing Taildrop files in the first message.
  public static let initialOutgoingFiles = NotifyWatchOpt(rawValue: 1 << 6)

  /// Include health state in the first message.
  public static let initialHealthState = NotifyWatchOpt(rawValue: 1 << 7)

  /// Rate-limit spammy netmap updates.
  public static let rateLimit = NotifyWatchOpt(rawValue: 1 << 8)

  /// Include primary actions in health state.
  public static let healthActions = NotifyWatchOpt(rawValue: 1 << 9)

  /// Include suggested exit node in the first message.
  public static let initialSuggestedExitNode = NotifyWatchOpt(rawValue: 1 << 10)

  /// Default options for general monitoring.
  ///
  /// Includes initial state, health state, engine updates, and rate limiting.
  public static let `default`: NotifyWatchOpt = [
    .initialState,
    .initialHealthState,
    .engineUpdates,
    .rateLimit,
  ]

  /// All initial state options.
  public static let allInitial: NotifyWatchOpt = [
    .initialState,
    .initialPrefs,
    .initialNetMap,
    .initialHealthState,
    .initialSuggestedExitNode,
  ]
}
