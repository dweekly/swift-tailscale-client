// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct HealthCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "health",
    abstract: "Display Tailscale health warnings"
  )

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let status = try await client.status()

    if json {
      try printJSON(["health": status.health])
      return
    }

    if status.health.isEmpty {
      print("✓ No health warnings")
    } else {
      print("=== Health Warnings ===")
      for warning in status.health {
        print("⚠ \(warning)")
      }
    }
  }
}
