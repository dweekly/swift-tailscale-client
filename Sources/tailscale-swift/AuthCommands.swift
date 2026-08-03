// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct LoginCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "login",
    abstract: "Start interactive login; prints the URL to open"
  )

  @Option(name: .shortAndLong, help: "Seconds to wait for login to complete")
  var timeout: Int = 300

  func run() async throws {
    let client = TailscaleClient()
    let stream = try await client.watchIPNBus(options: [.initialState])
    try await client.loginInteractive()
    print("Login started; waiting for the authentication URL…")

    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    for try await notify in stream {
      if let url = notify.browseToURL {
        print("\nOpen this URL to authenticate:\n\n  \(url)\n")
      }
      if notify.state == .running {
        print("✓ Logged in and running.")
        return
      }
      if let error = notify.errMessage, !error.isEmpty {
        print("Login error: \(error)")
        throw ExitCode(1)
      }
      if ContinuousClock.now > deadline {
        print("Timed out waiting for login to complete.")
        throw ExitCode(1)
      }
    }
  }
}

struct LogoutCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "logout",
    abstract: "Log this node out (expires its keys; requires --yes)"
  )

  @Flag(name: .customLong("yes"), help: "Confirm the logout (destructive)")
  var confirmed = false

  func run() async throws {
    guard confirmed else {
      print("Logout expires this node's keys and requires re-authentication.")
      print("Re-run with --yes to confirm.")
      throw ExitCode(1)
    }
    try await TailscaleClient().logout()
    print("Logged out.")
  }
}

struct SwitchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch",
    abstract: "List login profiles or switch to one"
  )

  @Argument(help: "Profile ID to switch to (omit to list profiles)")
  var profileID: String?

  @Flag(name: [.short, .long], help: "Output raw JSON.")
  var json = false

  func run() async throws {
    let client = TailscaleClient()

    guard let profileID else {
      let current = try? await client.currentProfile()
      let profiles = try await client.profiles()
      if json {
        try printJSON(profiles)
        return
      }
      if profiles.isEmpty {
        print("No saved profiles.")
        return
      }
      for profile in profiles {
        let marker = profile.id == current?.id ? "*" : " "
        let tailnet = profile.networkProfile?.displayName ?? profile.networkProfile?.domainName
        print("\(marker) \(profile.id)\t\(profile.name)\(tailnet.map { "  (\($0))" } ?? "")")
      }
      return
    }

    try await client.switchProfile(profileID)
    print("Switched to profile \(profileID).")
  }
}
