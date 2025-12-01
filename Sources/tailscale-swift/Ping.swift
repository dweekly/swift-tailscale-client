// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct PingCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ping",
    abstract: "Ping a Tailscale IP address to test connectivity"
  )

  @Argument(help: "Tailscale IP address to ping")
  var ip: String

  @Option(name: .shortAndLong, help: "Number of pings to send")
  var count: Int = 1

  @Option(name: .shortAndLong, help: "Ping type: disco, tsmp, icmp, or peerAPI")
  var type: String = "disco"

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

    print("PING \(ip) using \(pingType.rawValue)...")

    var successCount = 0
    var totalLatency: Double = 0

    for i in 0..<count {
      do {
        let result = try await client.ping(ip: ip, type: pingType)

        if let error = result.error, !error.isEmpty {
          print("ping \(i + 1): error - \(error)")
        } else if let latency = result.latencyDescription {
          successCount += 1
          totalLatency += result.latencySeconds ?? 0

          var details = [String]()
          if result.isDirect {
            if let endpoint = result.endpoint {
              details.append("via \(endpoint)")
            }
          } else if let derpCode = result.derpRegionCode {
            details.append("via DERP(\(derpCode))")
          }

          let detailStr = details.isEmpty ? "" : " \(details.joined(separator: " "))"
          print("ping \(i + 1): \(result.nodeName ?? ip) - \(latency)\(detailStr)")
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
}
