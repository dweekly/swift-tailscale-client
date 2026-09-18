// SPDX-License-Identifier: MIT
// Recipe: Monitor peer and connection changes without polling.
// Docs: Sources/TailscaleClient/TailscaleClient.docc/RecipeMonitoring.md

import TailscaleClient

/// Follows Tailscale state, health, and netmap changes for the life of the
/// process using 1.0 IPN bus events and bounded queues.
public func monitorTailscale(
  onChange: @escaping @Sendable (String) -> Void
) async throws {
  let client = TailscaleClient()

  let stream = try await client.watchIPNBusEvents(
    // Ask for current values up front so the first events seed your state.
    options: [.initialState, .initialHealthState, .initialNetMap],
    // Long-lived monitors should survive daemon restarts with backoff.
    retryPolicy: .default,
    // Bounded queues prevent slow consumers from leaking memory.
    bounds: StreamBufferBounds(maxEventCount: 256, overflowStrategy: .reportGap),
    // Malformed lines are skipped, not fatal; log them for bug reports.
    onUndecodableLine: { line, error in
      print("skipped undecodable line (\(error)): \(line.count) bytes")
    }
  )

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
      if notify.netMap != nil {
        // The netmap arrives as raw JSON (upstream shape churns); its
        // presence is the "peers changed" signal — re-query status() for
        // typed peer details when you see it.
        onChange("netmap updated")
      }
    case .lifecycle(let lifecycle):
      switch lifecycle {
      case .connected:
        onChange("lifecycle: connected")
      case .disconnected(let underlying):
        onChange("lifecycle: disconnected (\(underlying))")
      case .retrying(let attempt, let delay):
        onChange("lifecycle: retrying attempt \(attempt) in \(delay)")
      case .stateGap(let reason):
        onChange("lifecycle: stateGap (\(reason))")
      }
    }
  }
}
