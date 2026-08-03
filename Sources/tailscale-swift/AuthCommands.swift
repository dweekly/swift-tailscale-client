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
    guard timeout > 0 else {
      print("--timeout must be positive.")
      throw ExitCode(1)
    }
    let client = TailscaleClient()
    let stream = try await client.watchIPNBus(options: [.initialState])
    try await client.loginInteractive()
    print("Login started; waiting for the authentication URL…")

    // Race the bus observation against a real timer: a silent bus must
    // still time out.
    let seconds = timeout
    try await withThrowingTaskGroup(of: Bool.self) { group in
      group.addTask {
        for try await notify in stream {
          if let url = notify.browseToURL {
            print("\nOpen this URL to authenticate:\n\n  \(url)\n")
          }
          if notify.state == .running {
            return true
          }
          if let error = notify.errMessage, !error.isEmpty {
            print("Login error: \(error)")
            return false
          }
        }
        return false
      }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        return false
      }
      let finished = try await group.next() ?? false
      group.cancelAll()
      if finished {
        print("✓ Logged in and running.")
      } else {
        print("Login did not complete (timed out or failed).")
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
