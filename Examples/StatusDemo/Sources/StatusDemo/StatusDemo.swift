// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import TailscaleClient

/// A minimal end-to-end consumer of swift-tailscale-client: connect to the
/// local daemon, show who we are, probe optional features, and run a quick
/// netcheck. Exits non-zero when no daemon is reachable so CI can assert on it.
@main
struct StatusDemo {
  static func main() async {
    let client = TailscaleClient()

    do {
      let status = try await client.status()
      print("Connected to tailscaled \(status.version ?? "?")")
      print("Backend state: \(status.backendState.map { "\($0)" } ?? "unknown")")
      if let selfNode = status.selfNode {
        print("This node: \(selfNode.hostName) (\(selfNode.tailscaleIPs.joined(separator: ", ")))")
      }
      print("Peers: \(status.peers.count)")

      // Optional surfaces: probe rather than guess (availability is
      // build-dependent), and tolerate endpointUnavailable.
      do {
        let features = try await client.daemonFeatures()
        print("Optional daemon features: \(features.features.count)")
      } catch let error as TailscaleClientError {
        guard case .endpointUnavailable = error else { throw error }
        print("Optional daemon features: unsupported by this daemon build")
      }

      // Client-side STUN netcheck against the daemon's DERP map.
      let report = try await client.netcheck(options: Netcheck.Options(timeout: .seconds(3)))
      if report.udpWorking {
        let best = report.preferredDERPRegionID.map(String.init) ?? "?"
        print("Netcheck: UDP works; preferred DERP region \(best)")
        if let endpoint = report.globalV4 {
          print("Public IPv4 endpoint: \(endpoint)")
        }
      } else {
        print("Netcheck: no STUN responses (UDP blocked or empty DERP map)")
      }
    } catch {
      print("Could not talk to tailscaled: \(error)")
      print("Is Tailscale installed and running? See the README for discovery options.")
      exit(1)
    }
  }
}
