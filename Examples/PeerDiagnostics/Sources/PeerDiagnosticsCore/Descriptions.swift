// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import TailscaleClient

extension PingOutcome {
  /// One sentence describing the result, worded so a single relayed reply is never
  /// presented as the peer's settled path.
  public var summary: String {
    let count = pingsSent == 1 ? "1 ping" : "\(pingsSent) pings"
    switch reply {
    case .failure(let text):
      return "Failed after \(count): \(text)"
    case .reply(let path, let latency):
      let latencyText = latency.map { String(format: " in %.1f ms", $0 * 1000) } ?? ""
      let route = PingOutcome.describe(path)
      switch status {
      case .stoppedAtDirect:
        return "Reached directly \(route)\(latencyText) after \(count)."
      case .inProgress:
        return "Ping \(pingsSent) went \(route)\(latencyText); still trying for a direct path."
      case .reachedMaximum, .failed:
        return "The last of \(count) went \(route)\(latencyText). This is one measurement, "
          + "not necessarily the path the peer will settle on."
      }
    }
  }

  /// Names a path the way `tailscale ping` does.
  public static func describe(_ path: PingPath) -> String {
    switch path {
    case .direct(let endpoint): return "via \(endpoint)"
    case .peerRelay(let endpoint): return "via peer-relay(\(endpoint))"
    case .derp(let regionID, let code): return "via DERP(\(code ?? "region \(regionID)"))"
    case .unknown: return "by a path the daemon did not name"
    }
  }
}

extension Freshness {
  /// "current as of ...", "stale since ...", or "unknown".
  public var summary: String {
    let format = Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: false)
    switch self {
    case .unknown: return "unknown"
    case .current(let date): return "current as of \(date.formatted(format))"
    case .stale(let date): return "stale since \(date.formatted(format))"
    }
  }
}
