// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct SuggestExitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "suggest-exit",
    abstract: "Ask the daemon which exit node it would recommend"
  )

  @Flag(help: "Re-probe the network before answering (slower, fresher; Tailscale 1.86+)")
  var probe = false

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let suggestion = try await client.suggestExitNode(forceProbe: probe)

    if json {
      try printJSON(suggestion)
      return
    }

    guard let name = suggestion.name, !name.isEmpty else {
      print("No exit node suggestion available.")
      return
    }
    print("Suggested exit node: \(name)")
    if let id = suggestion.id {
      print("Stable ID: \(id)")
    }
    if let location = suggestion.location {
      let place = [location.city, location.country].compactMap { $0 }.joined(separator: ", ")
      if !place.isEmpty {
        print("Location: \(place)")
      }
    }
  }
}
