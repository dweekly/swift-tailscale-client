// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

// Entry point. With no action flag it opens the window; `--print` and `--snapshot` run
// without a window and exit. Nothing here ever writes to the daemon.
//
//   PeerDiagnostics                         the window, starting with fixture data
//   PeerDiagnostics --fixture --print       built-in fixture tailnet, no Tailscale needed
//   PeerDiagnostics --live --print          the Tailscale daemon on this Mac (read-only)
//   PeerDiagnostics --fixture --snapshot shot.png [--appearance dark]

import AppKit
import Foundation
import PeerDiagnosticsCore
import PeerDiagnosticsUI

/// Exit status for arguments that cannot be used (BSD `EX_USAGE`).
let usageExitCode: Int32 = 64
/// How long to wait for the first status read and watch event before giving up.
let connectTimeout: Duration = .seconds(10)
/// Longest a whole ping burst can take: every ping waits its full timeout plus spacing.
let burstTimeout =
  (PingBurstPolicy.perPingTimeout + PingBurstPolicy.spacing) * PingBurstPolicy.maximumPings
/// How often the command checks the model's published state while waiting.
let pollInterval: Duration = .milliseconds(50)

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

/// `--print`: the peers and one ping interpretation as text.
@MainActor
func printReport(_ options: LaunchOptions) async -> Int32 {
  let live = options.mode == .live
  if options.allowMacOSAppStoreDiscovery && !live {
    print("note: --allow-app-store-discovery only applies to --live")
  }

  let model = PeerDiagnosticsModel()
  model.allowMacOSAppStoreDiscovery = options.allowMacOSAppStoreDiscovery
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
    : model.peers.first { $0.name == FixtureDaemon.showcasePeerName }
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

/// `--snapshot`: renders the fixture scenario and writes the PNG.
@MainActor
func writeSnapshot(to path: String, appearance: LaunchOptions.Appearance) async -> Int32 {
  // A snapshot never shows a Dock icon or a window.
  NSApplication.shared.setActivationPolicy(.prohibited)
  do {
    let png = try await SnapshotRenderer.renderScenario(appearance: appearance)
    try png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(png.count) bytes, \(appearance.rawValue))")
    return 0
  } catch {
    fail("could not render the snapshot: \(error)")
  }
}

let options: LaunchOptions
do {
  options = try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n\(LaunchOptions.usage)\n".utf8))
  exit(usageExitCode)
}

switch options.action {
case .window:
  PeerDiagnosticsApp.launchOptions = options
  PeerDiagnosticsApp.main()
case .print:
  // The headless modes still run on the main run loop, which the model's tasks and (for
  // snapshots) AppKit drawing need. Each mode exits the process when it finishes.
  Task { @MainActor in exit(await printReport(options)) }
  RunLoop.main.run()
case .snapshot(let path):
  Task { @MainActor in exit(await writeSnapshot(to: path, appearance: options.appearance)) }
  RunLoop.main.run()
}
