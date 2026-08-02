// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct NetcheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "netcheck",
    abstract: "Probe DERP regions over STUN: latency, public IP, NAT behavior"
  )

  @Option(name: .shortAndLong, help: "Seconds to wait for STUN responses")
  var timeout: Double = 3.0

  @Flag(help: "Skip IPv6 probing")
  var noIpv6 = false

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let map = try await client.derpMap()
    let options = Netcheck.Options(
      timeout: .milliseconds(Int(timeout * 1000)), probeIPv6: !noIpv6)
    let report = try await Netcheck(options: options).run(derpMap: map)

    if json {
      try printJSON(report)
      return
    }

    print("UDP: \(report.udpWorking ? "yes" : "no — traffic will use DERP relays")")
    print("IPv4: \(report.ipv4Working ? "yes" : "no")\(report.globalV4.map { " (\($0))" } ?? "")")
    print("IPv6: \(report.ipv6Working ? "yes" : "no")\(report.globalV6.map { " (\($0))" } ?? "")")
    if let varies = report.mappingVariesByDestination {
      print("Mapping varies by destination: \(varies ? "yes (hard NAT)" : "no")")
    }

    guard !report.regionLatencySeconds.isEmpty else { return }
    print("\nRegion latency:")
    let sorted = report.regionLatencySeconds.sorted { $0.value < $1.value }
    for (regionID, seconds) in sorted {
      let code = map.regions[regionID]?.regionCode ?? "?"
      let name = map.regions[regionID]?.regionName ?? "unknown"
      let marker = regionID == report.preferredDERPRegionID ? "  (preferred)" : ""
      let milliseconds = String(format: "%.1f", seconds * 1000)
      print("  \(regionID)\t\(code)\t\(name)\t\(milliseconds) ms\(marker)")
    }
  }
}
