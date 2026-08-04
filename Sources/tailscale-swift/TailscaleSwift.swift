// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation

@main
struct TailscaleSwift: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tailscale-swift",
    abstract: "Inspect a local Tailscale daemon (built on swift-tailscale-client)",
    subcommands: [
      Status.self,
      ServicesCommand.self,
      WhoIs.self,
      PrefsCommand.self,
      PingCommand.self,
      HealthCommand.self,
      MetricsCommand.self,
      UserMetricsCommand.self,
      WatchCommand.self,
      FeaturesCommand.self,
      DERPMapCommand.self,
      SuggestExitCommand.self,
      NetcheckCommand.self,
      DNSCommand.self,
      CheckForwardingCommand.self,
      ServeCommand.self,
      CertCommand.self,
      SetCommand.self,
      LoginCommand.self,
      LogoutCommand.self,
      SwitchCommand.self,
    ]
  )
}
