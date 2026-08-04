// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct ServicesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "services",
    abstract: "List Tailscale Services (VIP services) visible to this node"
  )

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()
    let services = try await client.services()

    if json {
      try printJSON(services)
      return
    }

    if services.isEmpty {
      print("No Tailscale Services visible to this node")
      return
    }

    print("=== Tailscale Services ===")
    for name in services.keys.sorted() {
      guard let service = services[name] else { continue }
      let label =
        (service.displayName?.isEmpty == false) ? "\(name) (\(service.displayName!))" : name
      print(label)
      if !service.addresses.isEmpty {
        print("  Addresses: \(service.addresses.joined(separator: ", "))")
      }
      if !service.ports.isEmpty {
        print("  Ports:     \(service.ports.joined(separator: ", "))")
      }
      for action in service.actions {
        let display = action.displayName.map { " — \($0)" } ?? ""
        print("  Action:    \(action.type) on port \(action.port)\(display)")
      }
    }
  }
}
