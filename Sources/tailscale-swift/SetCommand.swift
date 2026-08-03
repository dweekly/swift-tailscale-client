// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct SetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract: "Change daemon preferences (the write APIs)",
    subcommands: [SetExitNodeCommand.self, SetShieldsUpCommand.self, SetAcceptRoutesCommand.self]
  )
}

private func applyChange(_ change: MaskedPrefs, json: Bool) async throws {
  let client = TailscaleClient()
  let updated = try await client.editPrefs(change)
  if json {
    try printJSON(updated)
  } else {
    print("Applied.")
  }
}

struct SetExitNodeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "exit-node",
    abstract: "Select an exit node by stable ID, or clear with an empty string"
  )

  @Argument(help: "Stable node ID of the exit node (\"\" to clear)")
  var nodeID: String

  @Flag(help: "Keep direct LAN access while the exit node is active")
  var allowLanAccess = false

  @Flag(name: [.short, .long], help: "Output the updated prefs as JSON.")
  var json = false

  func run() async throws {
    var change = MaskedPrefs()
    change.exitNodeID = nodeID
    if allowLanAccess { change.exitNodeAllowLANAccess = true }
    try await applyChange(change, json: json)
  }
}

struct SetShieldsUpCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "shields-up",
    abstract: "Block or allow all incoming connections"
  )

  @Argument(help: "true or false")
  var enabled: Bool

  @Flag(name: [.short, .long], help: "Output the updated prefs as JSON.")
  var json = false

  func run() async throws {
    var change = MaskedPrefs()
    change.shieldsUp = enabled
    try await applyChange(change, json: json)
  }
}

struct SetAcceptRoutesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "accept-routes",
    abstract: "Accept or ignore subnet routes advertised by other nodes"
  )

  @Argument(help: "true or false")
  var enabled: Bool

  @Flag(name: [.short, .long], help: "Output the updated prefs as JSON.")
  var json = false

  func run() async throws {
    var change = MaskedPrefs()
    change.routeAll = enabled
    try await applyChange(change, json: json)
  }
}
