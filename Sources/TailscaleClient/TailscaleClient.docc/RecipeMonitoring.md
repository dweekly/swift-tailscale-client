# Recipe: Monitor Peer and Connection Changes Without Polling

One long-lived `watchIPNBus` stream replaces every status-polling timer.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

Every snippet below is compiled by CI from
[`Examples/Recipes`](https://github.com/dweekly/swift-tailscale-client/tree/main/Examples/Recipes).

## The pattern

```swift
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
```

## Why re-read status()

Tailscale 1.104 and later no longer send the network map over the IPN bus,
and reject a watch that asks for it (`initialNetMap`) or for `rateLimit`; the
client then opens the watch without them. Peer changes now arrive through
`peerChanges` (and `peerPatches`) in fields ``IPNNotify`` does not model yet.
A notification that carries only those fields still decodes, with its modeled
fields `nil`, so the recipe treats every notification, reconnect, and state
gap as a reason to call ``TailscaleClient/status(query:)``. The same
subscription works on 1.102 daemons. A monitor that sees frequent changes can
coalesce those calls (for example, at most one per second).

## Why not poll?

Polling `status()` costs a request per tick, lags by the poll interval, and
misses transient states entirely. The IPN bus pushes every transition the
daemon makes, including health warnings that never show up in a status diff.

## See also

- <doc:Streaming> — skip-and-report semantics, reconnect backoff policy.
- <doc:RecipeMenuBar> — the same stream driving a UI.
