// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct PrefsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prefs",
    abstract: "Display current Tailscale preferences"
  )

  @Flag(name: .shortAndLong, help: "Show all preference fields")
  var verbose = false

  func run() async throws {
    let client = TailscaleClient()
    let prefs = try await client.prefs()

    print("=== Tailscale Preferences ===")

    // Connection state
    print("\n--- Connection ---")
    if let wantRunning = prefs.wantRunning {
      print("Want Running: \(wantRunning)")
    }
    if let loggedOut = prefs.loggedOut {
      print("Logged Out: \(loggedOut)")
    }

    // Exit node
    if let exitNodeID = prefs.exitNodeID, !exitNodeID.isEmpty {
      print("\n--- Exit Node ---")
      print("Exit Node ID: \(exitNodeID)")
      if let exitNodeIP = prefs.exitNodeIP, !exitNodeIP.isEmpty {
        print("Exit Node IP: \(exitNodeIP)")
      }
      if let lanAccess = prefs.exitNodeAllowLANAccess {
        print("Allow LAN Access: \(lanAccess)")
      }
    }

    // Network settings
    print("\n--- Network ---")
    if let routeAll = prefs.routeAll {
      print("Route All Traffic: \(routeAll)")
    }
    if let shieldsUp = prefs.shieldsUp {
      print("Shields Up: \(shieldsUp)")
    }
    if let corpDNS = prefs.corpDNS {
      print("MagicDNS: \(corpDNS)")
    }

    // Advertised routes
    if !prefs.advertiseRoutes.isEmpty {
      print("\n--- Advertised Routes ---")
      for route in prefs.advertiseRoutes {
        print("  \(route)")
      }
    }

    // Tags
    if !prefs.advertiseTags.isEmpty {
      print("\n--- Tags ---")
      print(prefs.advertiseTags.joined(separator: ", "))
    }

    // Services
    print("\n--- Services ---")
    if let runSSH = prefs.runSSH {
      print("SSH Server: \(runSSH)")
    }
    if let runWebClient = prefs.runWebClient {
      print("Web Client: \(runWebClient)")
    }

    if verbose {
      print("\n--- Additional Settings ---")
      if let controlURL = prefs.controlURL {
        print("Control URL: \(controlURL)")
      }
      if let hostname = prefs.hostname, !hostname.isEmpty {
        print("Hostname: \(hostname)")
      }
      if let profileName = prefs.profileName, !profileName.isEmpty {
        print("Profile: \(profileName)")
      }
      if let operatorUser = prefs.operatorUser, !operatorUser.isEmpty {
        print("Operator User: \(operatorUser)")
      }
      if let forceDaemon = prefs.forceDaemon {
        print("Force Daemon: \(forceDaemon)")
      }
      if let noSNAT = prefs.noSNAT {
        print("No SNAT: \(noSNAT)")
      }
      if let postureChecking = prefs.postureChecking {
        print("Posture Checking: \(postureChecking)")
      }
      if let autoUpdate = prefs.autoUpdate {
        print("\n--- Auto Update ---")
        if let check = autoUpdate.check {
          print("Check: \(check)")
        }
        if let apply = autoUpdate.apply {
          print("Apply: \(apply)")
        }
      }
    }
  }
}
