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

  func run() async throws {
    let client = TailscaleClient()
    let status = try await client.status()

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
