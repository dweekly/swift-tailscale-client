// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct WhoIs: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "whois",
    abstract: "Look up identity information for a Tailscale IP address"
  )

  @Argument(help: "Tailscale IP address or node key to look up")
  var address: String

  @Flag(name: .shortAndLong, help: "Show detailed node information")
  var verbose = false

  func run() async throws {
    let client = TailscaleClient()
    let response = try await client.whois(address: address)

    if let node = response.node {
      print("=== Node ===")
      if let name = node.computedName ?? node.name {
        print("Name: \(name)")
      }
      print("ID: \(node.id)")
      if let stableID = node.stableID {
        print("Stable ID: \(stableID)")
      }
      if !node.addresses.isEmpty {
        print("Addresses: \(node.addresses.joined(separator: ", "))")
      }
      if let online = node.online {
        print("Online: \(online)")
      }
      if let expired = node.expired {
        print("Expired: \(expired)")
      }

      if verbose {
        if let hostinfo = node.hostinfo {
          print("\n=== Host Info ===")
          if let os = hostinfo.os {
            print("OS: \(os)")
          }
          if let osVersion = hostinfo.osVersion {
            print("OS Version: \(osVersion)")
          }
          if let hostname = hostinfo.hostname {
            print("Hostname: \(hostname)")
          }
          if let deviceModel = hostinfo.deviceModel {
            print("Device: \(deviceModel)")
          }
          if let tsVersion = hostinfo.tailscaleVersion {
            print("Tailscale: \(tsVersion)")
          }
        }

        if !node.endpoints.isEmpty {
          print("\n=== Endpoints ===")
          for endpoint in node.endpoints {
            print("  \(endpoint)")
          }
        }

        if !node.tags.isEmpty {
          print("\n=== Tags ===")
          print(node.tags.joined(separator: ", "))
        }

        if let keyExpiry = node.keyExpiry {
          print("\nKey Expiry: \(keyExpiry)")
        }
        if let created = node.created {
          print("Created: \(created)")
        }
        if let lastSeen = node.lastSeen {
          print("Last Seen: \(lastSeen)")
        }
      }
    }

    if let user = response.userProfile {
      print("\n=== User ===")
      print("ID: \(user.id)")
      if let loginName = user.loginName {
        print("Login: \(loginName)")
      }
      if let displayName = user.displayName {
        print("Display Name: \(displayName)")
      }
    }
  }
}
