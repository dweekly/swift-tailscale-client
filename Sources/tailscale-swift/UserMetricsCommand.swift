// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct UserMetricsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "usermetrics",
    abstract: "Display stable user-facing metrics (Prometheus format)",
    discussion: "The documented metrics behind 'tailscale metrics print', as opposed to the "
      + "internal counters shown by 'metrics'."
  )

  @Option(name: .shortAndLong, help: "Filter metrics by prefix (e.g., 'tailscaled_inbound')")
  var filter: String?

  func run() async throws {
    let client = TailscaleClient()
    let metrics = try await client.userMetrics()

    if let filter = filter {
      let lines = metrics.split(separator: "\n")
      for line in lines where line.hasPrefix(filter) || line.hasPrefix("#") {
        print(line)
      }
    } else {
      print(metrics)
    }
  }
}
