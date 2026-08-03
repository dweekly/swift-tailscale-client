// SPDX-License-Identifier: MIT
// Recipe: Monitor peer and connection changes without polling.
// Docs: Sources/TailscaleClient/TailscaleClient.docc/RecipeMonitoring.md

import TailscaleClient

/// Follows Tailscale state, health, and netmap changes for the life of the
/// process. One long-lived stream replaces any status-polling timer.
public func monitorTailscale(
  onChange: @escaping @Sendable (String) -> Void
) async throws {
  let client = TailscaleClient()

  let stream = try await client.watchIPNBus(
    // Ask for current values up front so the first events seed your state.
    options: [.initialState, .initialHealthState, .initialNetMap],
    // Long-lived monitors should survive daemon restarts.
    reconnect: .default,
    // Malformed lines are skipped, not fatal; log them for bug reports.
    onUndecodableLine: { line, error in
      print("skipped undecodable notify (\(error)): \(line.count) bytes")
    })

  for try await notify in stream {
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
  }
}
