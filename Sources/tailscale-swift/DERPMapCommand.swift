// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct DERPMapCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "derpmap",
    abstract: "Display the DERP relay map the daemon is using"
  )

  @Flag(name: .shortAndLong, help: "List every relay node, not just regions")
  var verbose = false

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let map = try await client.derpMap()

    if json {
      try printJSON(map)
      return
    }

    if map.regions.isEmpty {
      print("DERP map is empty.")
      return
    }
    if map.omitDefaultRegions {
      print("(custom map: default Tailscale regions omitted)\n")
    }

    for region in map.sortedRegions {
      var flags = [String]()
      if region.avoid { flags.append("avoid") }
      if region.noMeasureNoHome { flags.append("no-measure") }
      let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
      print("\(region.regionID)\t\(region.regionCode)\t\(region.regionName)\(suffix)")

      if verbose {
        for node in region.nodes {
          var details = [String]()
          if let ipv4 = node.ipv4 { details.append(ipv4) }
          if let ipv6 = node.ipv6 { details.append(ipv6) }
          if let stun = node.effectiveSTUNPort {
            details.append("stun:\(stun)")
          } else {
            details.append("stun:off")
          }
          if node.stunOnly { details.append("stun-only") }
          details.append("derp:\(node.effectiveDERPPort)")
          print("\t\(node.hostName)  \(details.joined(separator: "  "))")
        }
      }
    }
    if !verbose {
      let nodeCount = map.regions.values.reduce(0) { $0 + $1.nodes.count }
      print("\n\(map.regions.count) regions, \(nodeCount) nodes (use --verbose for nodes)")
    }
  }
}
