// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// The type of ping to perform.
public enum PingType: String, Sendable {
  /// Disco ping - uses Tailscale's disco protocol.
  case disco = "disco"
  /// TSMP ping - Tailscale Message Protocol.
  case tsmp = "TSMP"
  /// ICMP ping - standard ICMP echo.
  case icmp = "ICMP"
  /// PeerAPI ping - pings the peer's API server.
  case peerAPI = "peerAPI"
}

/// Result of a ping operation from `/localapi/v0/ping`.
public struct PingResult: Sendable, Decodable {
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

  /// Whether the ping used a direct connection (not DERP).
  public var isDirect: Bool {
    endpoint != nil && (derpRegionID == nil || derpRegionID == 0)
  }
}
