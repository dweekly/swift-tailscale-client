// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation

@main
struct TailscaleSwift: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tailscale-swift",
    abstract: "Development CLI for swift-tailscale-client",
    subcommands: [
      Status.self,
      WhoIs.self,
      PrefsCommand.self,
      PingCommand.self,
      HealthCommand.self,
      MetricsCommand.self,
      WatchCommand.self,
    ]
  )
}
