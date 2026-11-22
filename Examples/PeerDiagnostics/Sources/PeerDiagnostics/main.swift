// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

// Headless entry point over PeerDiagnosticsCore. Prints the peers and one ping
// interpretation, then exits. It never writes to the daemon.
//
//   PeerDiagnostics --fixture --print   built-in fixture tailnet, no Tailscale needed
//   PeerDiagnostics --live --print      the Tailscale daemon on this Mac (read-only)

import Foundation
import PeerDiagnosticsCore

/// How long to wait for the first status read and watch event before giving up.
let connectTimeout: Duration = .seconds(10)
/// Longest a whole ping burst can take: every ping waits its full timeout plus spacing.
let burstTimeout =
  (PingBurstPolicy.perPingTimeout + PingBurstPolicy.spacing) * PingBurstPolicy.maximumPings
/// How often the command checks the model's published state while waiting.
let pollInterval: Duration = .milliseconds(50)
/// The fixture peer whose burst shows a DERP reply upgrading to direct.
let fixturePeerName = "example-laptop"

/// Waits until `condition` holds or `timeout` passes; returns whether it held.
@MainActor
func waitFor(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    if ContinuousClock.now >= deadline { return false }
    try? await Task.sleep(for: pollInterval)
  }
  return true
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

@MainActor
func run(arguments: [String]) async -> Int32 {
  guard arguments.contains("--print") else {
    print("usage: PeerDiagnostics [--fixture | --live] --print")
    print("The windowed app arrives in a later change; --print is the headless mode.")
    return 64
  }
  let live = arguments.contains("--live")
  if arguments.contains("--allow-app-store-discovery") && !live {
    print("note: --allow-app-store-discovery only applies to --live")
  }

  let model = PeerDiagnosticsModel()
  model.allowMacOSAppStoreDiscovery = arguments.contains("--allow-app-store-discovery")
  if live { model.switchMode(to: .live) } else { model.start() }
  defer { model.stop() }

  let settled = await waitFor(connectTimeout) {
    if case .unavailable = model.connection { return true }
    if case .current = model.peerListFreshness, model.connection == .connected { return true }
    return false
  }
  if case .unavailable(let reason) = model.connection {
    fail("no Tailscale daemon reachable. \(reason)")
  }
  guard settled else { fail("timed out waiting for the daemon's status and watch") }

  print("mode: \(model.mode.rawValue)")
  print("connected via: \(model.connectionSummary ?? "unknown")")
  print("peers (\(model.peers.count), \(model.peerListFreshness.summary)):")
  for peer in model.peers {
    let state = peer.isOnline ? "online " : "offline"
    print("  \(state) \(peer.name) [\(peer.operatingSystem ?? "?")] \(peer.tailscaleIP ?? "-")")
  }

  let gotNotification = await waitFor(connectTimeout) { model.notificationsReceived > 0 }
  print(
    "initial watch notification: \(gotNotification ? "received" : "not received within timeout")")

  let target =
    live
    ? model.peers.first { $0.isOnline }
    : model.peers.first { $0.name == fixturePeerName }
  guard let target else {
    print("ping: skipped, no online peer to ping")
    return live ? 1 : 0
  }
  model.select(peerID: target.id)
  model.pingSelectedPeer()
  _ = await waitFor(burstTimeout) { !model.isPinging }
  guard let outcome = model.pingResult else { fail("the ping burst produced no result") }
  print("ping \(target.name): \(outcome.summary)")
  print("ping result: \(model.pingFreshness.summary)")
  return gotNotification ? 0 : 1
}

let status = await run(arguments: CommandLine.arguments)
exit(status)
