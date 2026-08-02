# Streaming Guide

Consume real-time state changes from the IPN bus instead of polling.

## Watching the IPN bus

``TailscaleClient/watchIPNBus(options:reconnect:onUndecodableLine:)`` returns
an `AsyncThrowingStream` of ``IPNNotify`` values — the same notification bus
the Tailscale GUI uses:

```swift
for try await notify in try await client.watchIPNBus() {
  if let state = notify.state { print("backend:", state) }
  if let engine = notify.engine { print("↓\(engine.rBytes) ↑\(engine.wBytes)") }
  if let health = notify.health { print("warnings:", health.warnings ?? [:]) }
}
```

`options:` controls what the daemon sends. The default includes initial
state, health, and engine updates; add `.initialPrefs` / `.initialNetMap`
when you need a full snapshot on connect.

## Resilience semantics

Two failure modes matter for long-lived monitors, and they are handled
differently:

- **A line you can't decode never kills the stream.** Daemons routinely gain
  notification fields before this package models them. Undecodable lines are
  skipped; observe them via `onUndecodableLine:` if you want telemetry.
- **A dropped connection ends the stream** — unless you opt into
  reconnection:

```swift
let stream = try await client.watchIPNBus(
  options: [.initialState, .initialHealthState],
  reconnect: .default)  // exponential backoff, transparent re-dial
```

With a ``IPNBusReconnectPolicy`` the client re-dials with backoff and the
`for try await` loop simply keeps going; the daemon re-sends initial state
per your watch options on each new connection, so your UI can treat every
notification uniformly.

The first connection is always established before the stream is returned, so
an unreachable daemon throws immediately rather than poisoning the loop.

## The second streaming surface: logtap

``ExperimentalClient/logtap()`` streams the daemon's live log lines (see
<doc:StabilityTiers> for why it lives under `experimental`). It reuses the
same line-framing machinery but deliberately has **no** reconnection — it is
a debug tap:

```swift
for try await entry in try await client.experimental.logtap() {
  print(entry.text, terminator: "")
}
```

## Testing streams

`TailscaleClientMocks` scripts stream scenarios without a daemon —
`MockTransport.scriptedStream([...])` replays lines, delays, and injected
failures; `scriptedStreams([[...], [...]])` serves one script per connection
attempt, which is how the package's own reconnect tests work.
