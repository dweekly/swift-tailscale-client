// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct FeaturesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "features",
    abstract: "Show which optional features the daemon was compiled with"
  )

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let features = try await client.daemonFeatures()

    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(features)
      print(String(decoding: data, as: UTF8.self))
      return
    }

    if features.features.isEmpty {
      print("No optional features reported.")
      return
    }
    for (name, enabled) in features.features.sorted(by: { $0.key < $1.key }) {
      print("\(enabled ? "✅" : "❌") \(name)")
    }
  }
}
