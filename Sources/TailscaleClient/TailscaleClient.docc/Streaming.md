# Streaming Guide

Consume real-time state changes from the IPN bus instead of polling.

## Overview

The Tailscale daemon publishes real-time operational notifications over its IPN bus — the same event feed consumed by the official Tailscale menu bar and GUI applications. `TailscaleClient` provides first-class async streams for observing these events with bounded memory usage, automatic reconnection, and typed lifecycle tracking.

### Watching IPN Bus Events in 1.0

In swift-tailscale-client 1.0, the primary streaming entry point is ``TailscaleClient/watchIPNBusEvents(options:retryPolicy:bounds:onUndecodableLine:)``. It returns an `AsyncThrowingStream` of ``IPNBusEvent`` values:

```swift
let events = try await client.watchIPNBusEvents(
  options: [.initialState, .initialHealthState, .engineUpdates],
  retryPolicy: .default,
  bounds: .default
)

for try await event in events {
  switch event {
  case .notification(let notify):
    if let state = notify.state { print("Backend state:", state) }
    if let engine = notify.engine { print("Traffic: ↓\(engine.rBytes) ↑\(engine.wBytes)") }
    if let health = notify.health { print("Health warnings:", health.warnings ?? [:]) }

  case .lifecycle(let transition):
    switch transition {
    case .connected:
      print("Stream established to LocalAPI")
    case .disconnected(let detail):
      print("Stream disconnected: \(detail)")
    case .retrying(let attempt, let delay):
      print("Reconnection attempt \(attempt) scheduled in \(delay)")
    case .stateGap(let reason):
      print("Warning: event gap occurred (\(reason)); state refreshed")
    }
  }
}
```

### Event vs Lifecycle Distinction

Prior versions yielded only ``IPNNotify`` objects, which obscured connection state transitions and dropped updates during reconnects. ``IPNBusEvent`` separates notification payloads from connection lifecycle metadata:

- ``IPNBusEvent/notification(_:)``: Carries raw sparse state deltas from the daemon.
- ``IPNBusEvent/lifecycle(_:)``: Signals transport events:
  - ``IPNBusLifecycle/connected``: Validated HTTP response head metadata received from the daemon.
  - ``IPNBusLifecycle/disconnected(underlying:)``: Connection severed or closed.
  - ``IPNBusLifecycle/retrying(attempt:delay:)``: Active backoff delay before re-dialing.
  - ``IPNBusLifecycle/stateGap(reason:)``: Indicates intermediate notifications were dropped (due to buffer overflow or connection reset). When a state gap is emitted, the client re-syncs state from the daemon.

### Bounded Buffering and Overflow Protection

Streaming events are buffered in memory to decouple network delivery from downstream consumption speed. To guarantee that a slow consumer cannot cause unbounded memory growth, every stream enforces ``StreamBufferBounds``:

- ``StreamBufferBounds/maxEventCount``: Maximum queued events (default: 256).
- ``StreamBufferBounds/maxByteCount``: Maximum retained bytes (default: 16 MB).
- ``StreamBufferBounds/overflowStrategy``:
  - ``StreamOverflowStrategy/reportGap`` (default): Drops oldest unconsumed events and emits a `.lifecycle(.stateGap(reason: "buffer_overflow"))` event so the consumer knows state was dropped.
  - ``StreamOverflowStrategy/fail``: Immediately terminates the stream with ``TailscaleClientError/streamOverflow``.

### Reconnection and Backoff with Jitter

``StreamRetryPolicy`` governs automated recovery when connections drop:

- Classified retries: Fatal errors (HTTP 401/403, permission errors, non-existent sockets) terminate immediately without retrying. Transient network drops and daemon restarts trigger exponential backoff.
- Configurable delay limits (initial delay, capped maximum delay).
- Jitter factor to avoid thundering-herd reconnect storms when the daemon restarts.

### Legacy Sparse Notifications

For simple use cases where lifecycle events and buffer bounds are not required, ``TailscaleClient/watchIPNBus(options:reconnect:onUndecodableLine:)`` remains available as a convenience method returning a stream of raw ``IPNNotify`` values.

### Diagnostic Logtap Streaming

``ExperimentalClient/logtap()`` streams live internal daemon log lines for debugging. Because it is intended strictly as a diagnostic tool, it deliberately does not perform automated reconnects:

```swift
for try await entry in try await client.experimental.logtap() {
  print(entry.text, terminator: "")
}
```

### Testing Streaming Workflows

`TailscaleClientMocks` allows testing stream consumers in unit tests without requiring a running daemon:
- `MockTransport.scriptedStream([...])` replays scripted data chunks and injected errors.
- `MockTransport.scriptedStreams([[...], [...]])` supplies sequential scripts across reconnect attempts.

## Topics

### Streaming APIs
- ``TailscaleClient/watchIPNBusEvents(options:retryPolicy:bounds:onUndecodableLine:)``
- ``TailscaleClient/watchIPNBus(options:reconnect:onUndecodableLine:)``
- ``ExperimentalClient/logtap()``

### Event Models
- ``IPNBusEvent``
- ``IPNBusLifecycle``
- ``IPNNotify``
- ``NotifyWatchOpt``

### Resilience & Limits
- ``StreamRetryPolicy``
- ``StreamBufferBounds``
- ``StreamOverflowStrategy``
- ``StreamErrorClassification``
- ``IPNBusReconnectPolicy``

