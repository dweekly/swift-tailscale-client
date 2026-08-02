// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct CheckForwardingCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check-forwarding",
    abstract: "Check whether this host can forward traffic (subnet router / exit node preflight)"
  )

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let check = try await client.checkIPForwarding()

    if json {
      try printJSON(check)
      return
    }

    if check.isReady {
      print("✓ IP forwarding is configured; this host can route traffic")
    } else {
      print("⚠ \(check.warning ?? "IP forwarding is not configured")")
      throw ExitCode(1)
    }
  }
}
