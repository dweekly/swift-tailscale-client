// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import TailscaleClient

/// A small, made-up tailnet that needs no daemon, no permission, and no network.
///
/// Addresses come only from documentation ranges (100.64.0.x, 203.0.113.x, 2001:db8::).
/// Each peer is scripted to show one way a ping can turn out:
///
/// | Peer | Ping behavior |
/// |---|---|
/// | `example-peer` | direct reply every time |
/// | `example-laptop` | DERP on the first ping, direct from the second on |
/// | `example-relay` | through a peer relay |
/// | `example-far` | always DERP |
/// | `example-phone` | reply that names no path (unknown) |
/// | `example-offline` | never answers, so the ping times out |
/// | `example-broken` | the daemon reports an error |
public actor FixtureDaemon: DaemonConnection {
  /// How a fixture peer answers a ping.
  public enum PingScript: Sendable {
    case direct
    case derpThenDirect
    case peerRelay
    case derp
    case unknown
    case noReply
    case error(String)
  }

  struct FixturePeer {
    let node: NodeStatus
    let script: PingScript
  }

  private let peers: [FixturePeer]
  private var pingsSent: [String: Int] = [:]

  public nonisolated let connectionSummary = "built-in fixture tailnet (no daemon)"

  public init() {
    peers = FixtureDaemon.makePeers()
  }

  public func status() async throws -> StatusResponse {
    StatusResponse(
      version: "1.102.2-fixture",
      backendState: .running,
      tailscaleIPs: ["100.64.0.1", "2001:db8::1"],
      selfNode: NodeStatus(
        id: "nFIXTURESELF", publicKey: "nodekey:fixture-self", hostName: "this-mac",
        dnsName: "this-mac.example.ts.net.", operatingSystem: "macOS", userID: 1,
        tailscaleIPs: ["100.64.0.1", "2001:db8::1"], online: true),
      peers: Dictionary(uniqueKeysWithValues: peers.map { ($0.node.publicKey, $0.node) }),
      currentTailnet: TailnetStatus(name: "example.ts.net")
    )
  }

  public func ping(ip: String) async throws -> PingResult {
    guard let peer = peers.first(where: { $0.node.tailscaleIPs.contains(ip) }) else {
      return PingResult(ip: ip, error: "no matching peer")
    }
    let count = pingsSent[ip, default: 0] + 1
    pingsSent[ip] = count
    let name = peer.node.hostName
    switch peer.script {
    case .direct:
      return PingResult(
        ip: ip, nodeIP: ip, nodeName: name, latencySeconds: 0.004,
        endpoint: "203.0.113.10:41641")
    case .derpThenDirect where count > 1:
      return PingResult(
        ip: ip, nodeIP: ip, nodeName: name, latencySeconds: 0.011,
        endpoint: "203.0.113.11:41641")
    case .derpThenDirect, .derp:
      return PingResult(
        ip: ip, nodeIP: ip, nodeName: name, latencySeconds: 0.087, endpoint: "",
        derpRegionID: 1, derpRegionCode: "sfo")
    case .peerRelay:
      return PingResult(
        ip: ip, nodeIP: ip, nodeName: name, latencySeconds: 0.023,
        endpoint: "", peerRelay: "203.0.113.12:7777:vni:42")
    case .unknown:
      return PingResult(ip: ip, nodeIP: ip, nodeName: name, latencySeconds: 0.031)
    case .noReply:
      // Like a real offline peer: nothing comes back until the caller gives up.
      try await Task.sleep(for: .seconds(3600))
      throw CancellationError()
    case .error(let message):
      return PingResult(ip: ip, nodeIP: ip, nodeName: name, error: message)
    }
  }

  /// A watch that reports `.connected` and one initial notification, then stays open
  /// until the consumer stops iterating.
  public nonisolated func watchEvents() async throws -> AsyncThrowingStream<IPNBusEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.lifecycle(.connected))
      continuation.yield(.notification(IPNNotify(state: .running)))
    }
  }

  private static func makePeers() -> [FixturePeer] {
    func peer(
      _ number: Int, _ name: String, os: String, online: Bool, _ script: PingScript
    ) -> FixturePeer {
      FixturePeer(
        node: NodeStatus(
          id: "nFIXTURE\(number)", publicKey: "nodekey:fixture-\(number)", hostName: name,
          dnsName: "\(name).example.ts.net.", operatingSystem: os, userID: 1,
          tailscaleIPs: ["100.64.0.\(number)", "2001:db8::\(number)"], online: online),
        script: script)
    }
    return [
      peer(2, "example-peer", os: "linux", online: true, .direct),
      peer(3, "example-laptop", os: "macOS", online: true, .derpThenDirect),
      peer(4, "example-relay", os: "linux", online: true, .peerRelay),
      peer(5, "example-far", os: "windows", online: true, .derp),
      peer(6, "example-phone", os: "iOS", online: true, .unknown),
      peer(7, "example-offline", os: "linux", online: false, .noReply),
      peer(8, "example-broken", os: "linux", online: true, .error("no matching peer")),
    ]
  }
}
