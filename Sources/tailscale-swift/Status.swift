// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

private func formatBytes(_ bytes: UInt64) -> String {
  let units = ["B", "KB", "MB", "GB", "TB"]
  var value = Double(bytes)
  var unitIndex = 0
  while value >= 1024 && unitIndex < units.count - 1 {
    value /= 1024
    unitIndex += 1
  }
  if unitIndex == 0 {
    return "\(bytes) B"
  }
  return String(format: "%.1f %@", value, units[unitIndex])
}

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

    // Check if we're using an exit node
    let activeExitNode = status.peers.values.first { $0.exitNode == true }
    if let exitNode = activeExitNode {
      print("\n=== Using Exit Node ===")
      print("Exit Node: \(exitNode.hostName)")
      if !exitNode.tailscaleIPs.isEmpty {
        print("Exit Node IPs: \(exitNode.tailscaleIPs.joined(separator: ", "))")
      }
      print("Online: \(exitNode.online ?? false)")

      // Connection quality details
      if let curAddr = exitNode.currentAddress, !curAddr.isEmpty {
        print("Connection: \(curAddr)")
      } else if let relay = exitNode.relay, !relay.isEmpty {
        print("Connection: via DERP relay \(relay)")
      }

      if let relay = exitNode.relay, !relay.isEmpty,
        exitNode.currentAddress != nil
      {
        print("DERP Relay: \(relay)")
      }

      if let lastHandshake = exitNode.lastHandshake {
        let ago = Date().timeIntervalSince(lastHandshake)
        if ago < 120 {
          print("Last Handshake: \(Int(ago))s ago")
        } else if ago < 3600 {
          print("Last Handshake: \(Int(ago / 60))m ago")
        } else {
          print("Last Handshake: \(Int(ago / 3600))h ago")
        }
      }

      // Traffic stats
      if let rx = exitNode.rxBytes, let tx = exitNode.txBytes, rx > 0 || tx > 0 {
        print("Traffic: ↓\(formatBytes(rx)) ↑\(formatBytes(tx))")
      }
    }

    // Show available exit nodes
    let exitNodeOptions = status.peers.values.filter { $0.exitNodeOption == true }
    if !exitNodeOptions.isEmpty && verbose {
      print("\n=== Available Exit Nodes ===")
      for node in exitNodeOptions.sorted(by: { $0.hostName < $1.hostName }) {
        let marker = (node.exitNode == true) ? " (active)" : ""
        let onlineStatus = (node.online == true) ? "online" : "offline"
        print("  \(node.hostName)\(marker) [\(onlineStatus)]")
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
