// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct Status: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Fetch and display current Tailscale status"
  )

  @Flag(name: .shortAndLong, help: "Include detailed peer information")
  var verbose = false

  func run() async throws {
    let client = TailscaleClient()
    let status = try await client.status()

    print("=== Tailscale Status ===")
    if let backendState = status.backendState {
      print("Backend State: \(backendState)")
    }
    print("Version: \(status.version ?? "unknown")")

    if let selfNode = status.selfNode {
      print("\n=== Self Node ===")
      print("Hostname: \(selfNode.hostName)")
      print("ID: \(selfNode.id)")
      if let userID = selfNode.userID {
        print("User ID: \(userID)")
      }
      print("Online: \(selfNode.online ?? false)")
      print("Exit Node: \(selfNode.exitNode ?? false)")
      if !selfNode.tailscaleIPs.isEmpty {
        print("Tailscale IPs: \(selfNode.tailscaleIPs.joined(separator: ", "))")
      }
    }

    print("\n=== Network ===")
    print("Magic DNS Suffix: \(status.magicDNSSuffix ?? "none")")
    print("Current Tailnet: \(status.currentTailnet?.name ?? "unknown")")

    let peers = status.peers
    print("\n=== Peers (\(peers.count)) ===")
    if verbose {
      for (id, peer) in peers.sorted(by: { $0.key < $1.key }) {
        print("\nPeer: \(peer.hostName)")
        print("  ID: \(id)")
        print("  Online: \(peer.online ?? false)")
        if !peer.tailscaleIPs.isEmpty {
          print("  IPs: \(peer.tailscaleIPs.joined(separator: ", "))")
        }
        if let lastSeen = peer.lastSeen {
          print("  Last Seen: \(lastSeen)")
        }
      }
    } else {
      let onlinePeers = peers.values.filter { $0.online == true }
      print("Online: \(onlinePeers.count)/\(peers.count)")
    }
  }
}
