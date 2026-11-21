// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// The type of ping to perform.
///
/// Only a ``disco`` ping reports how the reply travelled. ``tsmp``, ``icmp``, and ``peerAPI``
/// replies measure latency but never name a path, so their ``PingResult/path`` is
/// ``PingPath/unknown``.
public enum PingType: String, Sendable, Codable {
  /// Disco ping - uses Tailscale's disco protocol. The only type whose reply reports a path.
  case disco = "disco"
  /// TSMP ping - Tailscale Message Protocol.
  case tsmp = "TSMP"
  /// ICMP ping - standard ICMP echo.
  case icmp = "ICMP"
  /// PeerAPI ping - pings the peer's API server.
  ///
  /// Sends `peerapi`, upstream's `tailcfg.PingPeerAPI` value.
  case peerAPI = "peerapi"

  /// Creates a ping type from its wire value.
  ///
  /// Accepts each case's raw value, plus `"peerAPI"` (the spelling sent by 1.0.x) for
  /// ``peerAPI``, so values persisted by earlier releases still decode.
  ///
  /// - Parameter rawValue: The wire value, matched case-sensitively.
  public init?(rawValue: String) {
    switch rawValue {
    case "disco": self = .disco
    case "TSMP": self = .tsmp
    case "ICMP": self = .icmp
    case "peerapi", "peerAPI": self = .peerAPI
    default: return nil
    }
  }
}

/// How a successful disco ping reply reached the peer, as reported by the daemon.
///
/// Read it from ``PingResult/path``. The classification follows the official `tailscale ping`
/// command: a nonempty ``PingResult/peerRelay`` means ``peerRelay(endpoint:)``; otherwise a
/// nonzero ``PingResult/derpRegionID`` means ``derp(regionID:regionCode:)``; otherwise a
/// nonempty ``PingResult/endpoint`` means ``direct(endpoint:)``. The daemon sends these fields
/// as empty strings or zero rather than omitting them, so empty and zero count as absent.
///
/// One reply is one measurement. The first disco ping to an idle peer often travels over DERP
/// while a direct path is still forming, which is why `tailscale ping` repeats until it sees a
/// direct reply. A single ``derp(regionID:regionCode:)`` result says how that one reply
/// travelled, not which path the peer will settle on.
///
/// ```swift
/// func describe(_ result: PingResult) -> String {
///   switch result.path {
///   case .direct(let endpoint)?: return "direct via \(endpoint)"
///   case .peerRelay(let endpoint)?: return "peer relay via \(endpoint)"
///   case .derp(_, let code)?: return "DERP via \(code ?? "unknown region")"
///   case .unknown?: return "reply without a path"
///   case nil: return "failed: \(result.error ?? "")"
///   }
/// }
/// ```
///
/// This example is compiled and tested as `describe(_:)` in `Examples/Recipes`.
public enum PingPath: Sendable, Equatable, Hashable {
  /// The reply came straight from the peer at a UDP endpoint in `ip:port` form.
  case direct(endpoint: String)
  /// The reply came through a Tailscale peer relay; `endpoint` is in upstream's
  /// `{ip}:{port}:vni:{vni}` form.
  case peerRelay(endpoint: String)
  /// The reply came through a DERP relay server.
  ///
  /// `regionCode` is the short region code (for example `"sfo"`), or `nil` when the daemon
  /// sent an empty code.
  case derp(regionID: Int, regionCode: String?)
  /// The reply succeeded but named no path.
  ///
  /// TSMP, ICMP, and peerAPI pings always produce this, because only disco replies carry path
  /// fields. A disco reply produces it only if it names no path this release understands.
  case unknown
}

/// Result of a ping operation from `/localapi/v0/ping`.
public struct PingResult: Sendable, Codable, Equatable {
  /// The IP address that was pinged.
  public let ip: String?

  /// The Tailscale IP of the node handling the IP.
  public let nodeIP: String?

  /// DNS name base or hostname of the target node.
  public let nodeName: String?

  /// Error message if the ping failed.
  public let error: String?

  /// Round-trip latency in seconds.
  public let latencySeconds: Double?

  /// Direct UDP endpoint in "ip:port" format.
  public let endpoint: String?

  /// Peer relay endpoint in "ip:port:vni:vni" format.
  public let peerRelay: String?

  /// DERP region ID if the ping went through DERP.
  public let derpRegionID: Int?

  /// Three-letter DERP region code (e.g., "sfo").
  public let derpRegionCode: String?

  /// Port for peer API server (TSMP responses).
  public let peerAPIPort: UInt16?

  /// URL hit for peerapi pings.
  public let peerAPIURL: String?

  /// Whether the error is due to pinging the local node.
  public let isLocalIP: Bool?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    ip: String? = nil,
    nodeIP: String? = nil,
    nodeName: String? = nil,
    error: String? = nil,
    latencySeconds: Double? = nil,
    endpoint: String? = nil,
    peerRelay: String? = nil,
    derpRegionID: Int? = nil,
    derpRegionCode: String? = nil,
    peerAPIPort: UInt16? = nil,
    peerAPIURL: String? = nil,
    isLocalIP: Bool? = nil
  ) {
    self.ip = ip
    self.nodeIP = nodeIP
    self.nodeName = nodeName
    self.error = error
    self.latencySeconds = latencySeconds
    self.endpoint = endpoint
    self.peerRelay = peerRelay
    self.derpRegionID = derpRegionID
    self.derpRegionCode = derpRegionCode
    self.peerAPIPort = peerAPIPort
    self.peerAPIURL = peerAPIURL
    self.isLocalIP = isLocalIP
  }

  enum CodingKeys: String, CodingKey {
    case ip = "IP"
    case nodeIP = "NodeIP"
    case nodeName = "NodeName"
    case error = "Err"
    case latencySeconds = "LatencySeconds"
    case endpoint = "Endpoint"
    case peerRelay = "PeerRelay"
    case derpRegionID = "DERPRegionID"
    case derpRegionCode = "DERPRegionCode"
    case peerAPIPort = "PeerAPIPort"
    case peerAPIURL = "PeerAPIURL"
    case isLocalIP = "IsLocalIP"
  }

  /// Whether the ping was successful.
  public var isSuccess: Bool {
    error == nil || error?.isEmpty == true
  }

  /// Human-readable latency string.
  public var latencyDescription: String? {
    guard let latency = latencySeconds else { return nil }
    if latency < 0.001 {
      return String(format: "%.0f µs", latency * 1_000_000)
    } else if latency < 1.0 {
      return String(format: "%.2f ms", latency * 1000)
    } else {
      return String(format: "%.2f s", latency)
    }
  }

  /// How this reply reached the peer, or `nil` if the ping failed.
  ///
  /// `nil` when ``error`` is nonempty: a failed ping is never a measurement, even when the
  /// daemon also sent latency or path fields. Otherwise the first match of nonempty
  /// ``peerRelay``, nonzero ``derpRegionID``, and nonempty ``endpoint``, the same precedence
  /// as the official `tailscale ping` output; ``PingPath/unknown`` if none is set. Absent
  /// keys, empty strings, and zero IDs all count as unset, so replies from daemons that
  /// predate the `PeerRelay` field classify the same way.
  public var path: PingPath? {
    if let error, !error.isEmpty { return nil }
    if let relay = peerRelay, !relay.isEmpty { return .peerRelay(endpoint: relay) }
    if let regionID = derpRegionID, regionID != 0 {
      let code = derpRegionCode.flatMap { $0.isEmpty ? nil : $0 }
      return .derp(regionID: regionID, regionCode: code)
    }
    if let endpoint, !endpoint.isEmpty { return .direct(endpoint: endpoint) }
    return .unknown
  }

  /// Whether this reply came straight from the peer: `true` exactly when ``path`` is
  /// ``PingPath/direct(endpoint:)``.
  ///
  /// `false` for failed pings, DERP and peer-relay replies, and TSMP, ICMP, and peerAPI pings.
  public var isDirect: Bool {
    if case .direct = path { return true }
    return false
  }
}
