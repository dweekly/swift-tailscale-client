# Recipe: Monitor Peer and Connection Changes Without Polling

One long-lived `watchIPNBus` stream replaces every status-polling timer.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

Every snippet below is compiled by CI from
[`Examples/Recipes`](https://github.com/dweekly/swift-tailscale-client/tree/main/Examples/Recipes).

## The pattern

```swift
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
```

## Why not poll?

Polling `status()` costs a request per tick, lags by the poll interval, and
misses transient states entirely. The IPN bus pushes every transition the
daemon makes, including health warnings that never show up in a status diff.

## See also

- <doc:Streaming> — skip-and-report semantics, reconnect backoff policy.
- <doc:RecipeMenuBar> — the same stream driving a UI.
