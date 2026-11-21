// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import TailscaleClient

/// Where the sample gets its data.
public enum DiagnosticsMode: String, Sendable, Equatable {
  /// The built-in ``FixtureDaemon``: no Tailscale needed.
  case fixture
  /// The Tailscale daemon already running on this Mac.
  case live
}

/// The state of the sample's connection to its daemon.
public enum ConnectionState: Sendable, Equatable {
  /// Not started, or stopped.
  case stopped
  /// Finding the daemon and reading the first status.
  case connecting
  /// The watch is open; peer changes arrive as they happen.
  case connected
  /// The watch dropped and the library is about to try again.
  case reconnecting(attempt: Int)
  /// The watch dropped; a reconnect has not been scheduled yet.
  case disconnected
  /// The sample cannot reach a daemon. `reason` says what to do about it.
  case unavailable(reason: String)
}

/// Whether a piece of displayed data still describes the present.
public enum Freshness: Sendable, Equatable {
  /// Nothing has been read yet.
  case unknown
  /// Read at `asOf`, and nothing since has made it doubtful.
  case current(asOf: Date)
  /// Possibly out of date since `since` (connection lost, data too old, or stopped).
  case stale(since: Date)
}

/// One peer as the list shows it.
public struct PeerSummary: Sendable, Equatable, Identifiable {
  /// The node's stable ID from `status()`; selection is kept by this value.
  public let id: String
  /// The host name the peer reports.
  public let name: String
  /// Whether the coordination server last reported the peer online.
  public let isOnline: Bool
  /// The peer's operating system, when reported.
  public let operatingSystem: String?
  /// The peer's first Tailscale IP, which is the address the sample pings.
  public let tailscaleIP: String?

  public init(
    id: String, name: String, isOnline: Bool, operatingSystem: String?, tailscaleIP: String?
  ) {
    self.id = id
    self.name = name
    self.isOnline = isOnline
    self.operatingSystem = operatingSystem
    self.tailscaleIP = tailscaleIP
  }

  init(_ node: NodeStatus) {
    self.init(
      id: node.id, name: node.hostName, isOnline: node.online ?? false,
      operatingSystem: node.operatingSystem, tailscaleIP: node.tailscaleIPs.first)
  }
}

/// The numbers that shape a ping burst.
///
/// The official `tailscale ping` (v1.102.2, `cmd/tailscale/cli/ping.go`) sends up to 10
/// pings one second apart, stops at the first direct reply (`--until-direct`), and gives
/// each ping 5 seconds (`--timeout`). The sample keeps the spacing, the stop rule, and the
/// timeout, and halves the count: five pings are enough to see a DERP path upgrade to
/// direct, and they keep a burst to an always-relayed peer to about five seconds.
public enum PingBurstPolicy {
  /// Most pings one burst sends.
  public static let maximumPings = 5
  /// Pause between pings, as in `tailscale ping`.
  public static let spacing: Duration = .seconds(1)
  /// How long one ping may go unanswered. A disco ping to an offline peer gets no reply at
  /// all, so without this the wait would last until the request itself timed out.
  public static let perPingTimeout: Duration = .seconds(5)
  /// After this long a ping result is shown as stale: paths can change within seconds
  /// (DERP to direct, or a direct path lapsing), so an older reply describes the past.
  public static let resultMaximumAge: Duration = .seconds(30)
}

/// How long the sample waits after a watch event before re-reading `status()`, so a burst
/// of events (for example, reconnect plus state gap plus initial notification) causes one
/// read instead of several.
public let statusRefreshDebounce: Duration = .milliseconds(250)

/// Why a ping burst ended, or that it has not ended yet.
public enum BurstStatus: Sendable, Equatable {
  /// More pings may follow.
  case inProgress
  /// A reply came straight from the peer. This is the only ending that says which path the
  /// peer has settled on.
  case stoppedAtDirect
  /// Every ping was answered and none directly. The shown reply is one measurement of how
  /// the last ping travelled, not the peer's settled path.
  case reachedMaximum
  /// A ping failed or went unanswered, so the burst stopped.
  case failed
}

/// What the last ping of a burst found.
public enum PingReply: Sendable, Equatable {
  /// The peer answered. `path` is how this one reply travelled.
  case reply(path: PingPath, latencySeconds: Double?)
  /// No usable answer; the text is ready to show.
  case failure(String)
}

/// The latest ping result for the selected peer.
public struct PingOutcome: Sendable, Equatable {
  /// The peer this result belongs to.
  public let peerID: String
  /// The last reply (or failure) of the burst.
  public let reply: PingReply
  /// When that last reply arrived. Never changed by later status refreshes.
  public let measuredAt: Date
  /// How many pings the burst had sent when this result was recorded.
  public let pingsSent: Int
  /// Whether the burst is still running and, if not, why it stopped.
  public let status: BurstStatus

  /// `true` when the result describes the path the peer settled on (a direct reply). When
  /// `false`, a UI should word a successful reply as "this ping went via ...".
  public var isSettledPath: Bool { status == .stoppedAtDirect }
}

/// The parts of `status()` that identify which node and login the daemon is running as.
///
/// The sample compares the self node's stable ID, its user ID, and the tailnet name. If any
/// changes between two reads, the user switched profile or account and old results no
/// longer apply.
struct NodeIdentity: Equatable {
  let nodeID: String?
  let userID: UInt64?
  let tailnet: String?

  init(_ status: StatusResponse) {
    nodeID = status.selfNode?.id
    userID = status.selfNode?.userID
    tailnet = status.currentTailnet?.name
  }
}
