// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct MetricsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "metrics",
    abstract: "Display Tailscale internal metrics (Prometheus format)"
  )

  @Option(name: .shortAndLong, help: "Filter metrics by prefix (e.g., 'tailscale_')")
  var filter: String?

  func run() async throws {
    let client = TailscaleClient()
    let metrics = try await client.metrics()

    if let filter = filter {
      let lines = metrics.split(separator: "\n")
      for line in lines {
        if line.hasPrefix(filter) || line.hasPrefix("#") {
          print(line)
        }
      }
    } else {
      print(metrics)
    }
  }
}
