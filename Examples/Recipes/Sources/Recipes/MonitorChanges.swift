// SPDX-License-Identifier: MIT
// Recipe: Monitor peer and connection changes without polling.
// Docs: Sources/TailscaleClient/TailscaleClient.docc/RecipeMonitoring.md

import TailscaleClient

/// Follows Tailscale state, health, and peer changes for the life of the
/// process using 1.0 IPN bus events and bounded queues. Works on daemons
/// before and after Tailscale 1.104, which stopped sending the network map.
public func monitorTailscale(
  onChange: @escaping @Sendable (String) -> Void
) async throws {
  let client = TailscaleClient()

  let stream = try await client.watchIPNBusEvents(
    // Current state and health up front, then a notification whenever a peer
    // is added, removed, or changes. `.noNetMap` stops pre-1.104 daemons from
    // also sending the full network map; newer ones accept it as a no-op.
    options: [.initialState, .initialHealthState, .peerChanges, .noNetMap],
    // Long-lived monitors should survive daemon restarts with backoff.
    retryPolicy: .default,
    // Bounded queues prevent slow consumers from leaking memory.
    bounds: StreamBufferBounds(maxEventCount: 256, overflowStrategy: .reportGap),
    // Malformed lines are skipped, not fatal; log them for bug reports.
    onUndecodableLine: { line, error in
      print("skipped undecodable line (\(error)): \(line.count) bytes")
    }
  )

  // Typed peer details come from status(). IPNNotify does not model the
  // peer-change fields yet, so any notification (or a gap) means "re-read".
  func refreshPeers() async {
    guard let status = try? await client.status() else { return }
    let online = status.peers.values.filter { $0.online == true }.count
    onChange("peers: \(online) of \(status.peers.count) online")
  }

  for try await event in stream {
    switch event {
    case .notification(let notify):
      if let state = notify.state {
        onChange("backend: \(state)")
      }
      if let health = notify.health {
        let warnings = health.warnings ?? [:]
        onChange(warnings.isEmpty ? "healthy" : "warnings: \(warnings.keys.sorted())")
      }
      await refreshPeers()
    case .lifecycle(let lifecycle):
      switch lifecycle {
      case .connected:
        // Also fires after a reconnect: re-read what may have changed meanwhile.
        onChange("lifecycle: connected")
        await refreshPeers()
      case .disconnected(let underlying):
        onChange("lifecycle: disconnected (\(underlying))")
      case .retrying(let attempt, let delay):
        onChange("lifecycle: retrying attempt \(attempt) in \(delay)")
      case .stateGap(let reason):
        onChange("lifecycle: stateGap (\(reason))")
        await refreshPeers()
      }
    }
  }
}
