// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import TailscaleClient

// Short labels for the window. They live here, next to the state they describe, so the
// views only lay text out and the wording is tested without drawing anything.

extension PingOutcome {
  /// How the result reads at a glance: "Direct", "Peer relay", "DERP sfo", "Unknown", or
  /// "Failed". Distinguishable without color.
  public var pathTitle: String {
    switch reply {
    case .failure: return "Failed"
    case .reply(.direct, _): return "Direct"
    case .reply(.peerRelay, _): return "Peer relay"
    case .reply(.derp(let regionID, let code), _): return "DERP \(code ?? "region \(regionID)")"
    case .reply(.unknown, _): return "Unknown"
    }
  }

  /// Where the reply came from, when the daemon said, as a label and a value: the peer's
  /// own endpoint for a direct reply ("Endpoint"), the relay's for a peer-relay reply
  /// ("Relay"). `nil` for DERP, unknown, and failed results.
  public var endpoint: (label: String, value: String)? {
    switch reply {
    case .reply(.direct(let endpoint), _): return ("Endpoint", endpoint)
    case .reply(.peerRelay(let endpoint), _): return ("Relay", endpoint)
    default: return nil
    }
  }

  /// Round-trip time of the last reply, such as "11.0 ms"; `nil` if none was reported.
  public var latencyText: String? {
    guard case .reply(_, let latency?) = reply else { return nil }
    return String(format: "%.1f ms", latency * 1000)
  }

  /// "2 of up to 5".
  public var pingsSentText: String {
    "\(pingsSent) of up to \(PingBurstPolicy.maximumPings)"
  }

  /// A two-or-three-word verdict on what this result means for the peer's path:
  /// "Settled path", "Still pinging", "One measurement", or "Ping failed".
  public var conclusionTitle: String {
    if isSettledPath { return "Settled path" }
    switch status {
    case .inProgress: return "Still pinging"
    case .failed: return "Ping failed"
    case .stoppedAtDirect, .reachedMaximum: return "One measurement"
    }
  }
}

/// Formats clock times for the window in one fixed style, such as "15:04:05".
public enum DisplayTime {
  /// Hours, minutes, and seconds in `timeZone`. Seconds matter here: ping results go stale
  /// within a minute.
  public static func text(_ date: Date, timeZone: TimeZone = .current) -> String {
    date.formatted(
      Date.ISO8601FormatStyle(timeZone: timeZone).time(includingFractionalSeconds: false))
  }
}

extension Freshness {
  /// Whether the data should be shown with a "stale" warning.
  public var isStale: Bool {
    if case .stale = self { return true }
    return false
  }

  /// A sentence fragment for a label next to the data: "current as of 15:04:05",
  /// "stale since 15:04:35", or "not read yet".
  public func text(timeZone: TimeZone = .current) -> String {
    switch self {
    case .unknown: return "not read yet"
    case .current(let date): return "current as of \(DisplayTime.text(date, timeZone: timeZone))"
    case .stale(let date): return "stale since \(DisplayTime.text(date, timeZone: timeZone))"
    }
  }
}

extension ConnectionState {
  /// One or two words for the status area.
  public var title: String {
    switch self {
    case .stopped: return "Stopped"
    case .connecting: return "Connecting…"
    case .connected: return "Connected"
    case .reconnecting(let attempt): return "Reconnecting (attempt \(attempt))…"
    case .disconnected: return "Disconnected"
    case .unavailable: return "Unavailable"
    }
  }

  /// Whether the peers and results shown can be trusted to be updating.
  public var isHealthy: Bool { self == .connected }
}

extension DiagnosticsMode {
  /// The segment label in the mode control.
  public var title: String {
    switch self {
    case .fixture: return "Fixture"
    case .live: return "Live"
    }
  }

  /// One line saying what the mode reads and what it never does.
  public var explanation: String {
    switch self {
    case .fixture:
      return "A built-in, made-up tailnet. Needs no Tailscale, permission, or network."
    case .live:
      return "Reads status, pings the peer you select, and watches for changes. "
        + "Never changes Tailscale settings."
    }
  }
}

extension PeerSummary {
  /// "macOS · 100.64.0.3", skipping parts the daemon did not report.
  public var detailText: String {
    [operatingSystem, tailscaleIP].compactMap { $0 }.joined(separator: " · ")
  }
}

extension PeerDiagnosticsModel {
  /// The peer to select when a list first loads and nothing is selected: the fixture's
  /// showcase peer in fixture mode, otherwise the first online peer. Never pings.
  public func suggestedPeerID() -> String? {
    if mode == .fixture,
      let showcase = peers.first(where: { $0.name == FixtureDaemon.showcasePeerName })
    {
      return showcase.id
    }
    return (peers.first { $0.isOnline } ?? peers.first)?.id
  }

  /// What the detail pane says when no peer is selected, as a title and one sentence.
  public var emptySelectionText: (title: String, message: String) {
    if !peers.isEmpty {
      return ("No peer selected", "Choose a peer in the sidebar to see how a ping reaches it.")
    }
    switch connection {
    case .connected:
      return ("No peers", "This node has no peers yet, or the daemon has not reported them.")
    case .connecting, .reconnecting:
      return ("Loading peers…", "Waiting for the daemon's first status.")
    case .stopped, .disconnected, .unavailable:
      return ("No peers to show", "Peers appear once a daemon is connected.")
    }
  }

  /// Whether the Ping button can do anything: connected, a peer selected that has an
  /// address, and no burst already running.
  public var canPing: Bool {
    connection == .connected && selectedPeer?.tailscaleIP != nil && !isPinging
  }
}
