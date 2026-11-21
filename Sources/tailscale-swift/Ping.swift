// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct PingCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ping",
    abstract: "Ping a Tailscale IP address to test connectivity",
    discussion: """
      Each reply line names how that reply travelled, using the same rules as \
      `tailscale ping`: "via <ip:port>" for a direct path, "via peer-relay(<endpoint>)" \
      for a peer relay, "via DERP(<region>)" for a DERP relay. Replies that carry no \
      path (always the case for tsmp, icmp, and peerapi pings) print the ping type, for \
      example "via TSMP". A disco ping to an idle peer can travel over DERP before a \
      direct path forms, so one reply is not the peer's settled path.
      """
  )

  @Argument(help: "Tailscale IP address to ping")
  var ip: String

  @Option(name: .shortAndLong, help: "Number of pings to send")
  var count: Int = 1

  @Option(
    name: .shortAndLong, help: "Ping type: disco, tsmp, icmp, or peerapi (peerAPI is also accepted)"
  )
  var type: String = "disco"

  @Flag(name: [.short, .long], help: "Output raw JSON (an array of ping results).")
  var json = false

  func run() async throws {
    let client = TailscaleClient()

    let pingType: PingType
    switch type.lowercased() {
    case "disco":
      pingType = .disco
    case "tsmp":
      pingType = .tsmp
    case "icmp":
      pingType = .icmp
    case "peerapi":
      pingType = .peerAPI
    default:
      print("Unknown ping type: \(type). Using disco.")
      pingType = .disco
    }

    if json {
      var results: [PingResult] = []
      for i in 0..<count {
        results.append(try await client.ping(ip: ip, type: pingType))
        if i < count - 1 {
          try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
      }
      try printJSON(results)
      return
    }

    print("PING \(ip) using \(pingType.rawValue)...")

    var successCount = 0
    var totalLatency: Double = 0

    for i in 0..<count {
      do {
        let result = try await client.ping(ip: ip, type: pingType)

        if let path = result.path {
          successCount += 1
          totalLatency += result.latencySeconds ?? 0
          let latency = result.latencyDescription ?? "no latency reported"
          let via = Self.describe(path, type: pingType)
          print("ping \(i + 1): \(result.nodeName ?? ip) - \(latency) via \(via)")
        } else {
          print("ping \(i + 1): error - \(result.error ?? "")")
        }

        // Small delay between pings
        if i < count - 1 {
          try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }
      } catch {
        print("ping \(i + 1): failed - \(error)")
      }
    }

    if count > 1 {
      print("\n--- \(ip) ping statistics ---")
      print(
        "\(count) packets transmitted, \(successCount) received, \(Int((1.0 - Double(successCount) / Double(count)) * 100))% packet loss"
      )
      if successCount > 0 {
        let avgLatency = totalLatency / Double(successCount) * 1000
        print(String(format: "avg latency: %.2f ms", avgLatency))
      }
    }
  }

  /// Renders a path the way `tailscale ping` does (`cmd/tailscale/cli/ping.go`), printing
  /// the ping type when the reply named no path.
  static func describe(_ path: PingPath, type: PingType) -> String {
    switch path {
    case .direct(let endpoint): return endpoint
    case .peerRelay(let endpoint): return "peer-relay(\(endpoint))"
    case .derp(let regionID, let regionCode): return "DERP(\(regionCode ?? "region \(regionID)"))"
    case .unknown: return type.rawValue
    }
  }
}
