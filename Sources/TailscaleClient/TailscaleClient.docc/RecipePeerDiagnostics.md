# Recipe: Show How a Ping Reached a Peer

Say whether a peer answered directly, through a peer relay, or through DERP,
and never present one relayed reply as the path the peer has settled on.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

The Peer Diagnostics sample is a small Mac app built on this package. Every
snippet below is compiled by CI from
[`Examples/PeerDiagnostics`](https://github.com/dweekly/swift-tailscale-client/tree/main/Examples/PeerDiagnostics).
Try it first; it needs no Tailscale installation:

```
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics
```

![The Peer Diagnostics window in fixture mode. The sidebar lists seven made-up peers with example-laptop selected; the detail pane shows its last ping went Direct, marked Settled path, with 11.0 ms latency, measured at 17:30:00, after 2 of up to 5 pings, and that the result is current.](peer-diagnostics-window)

It opens with a built-in, made-up tailnet (fixture mode). Choose **Live** in
the window to use the Tailscale daemon already running on your Mac. Live mode
reads status, pings the peer you select, and watches for changes; it never
changes Tailscale settings.

## Classify a ping with its path

``PingResult/path`` reads the reply the way the official `tailscale ping`
does and returns a ``PingPath``: `.direct`, `.peerRelay`, `.derp`, or
`.unknown` for a reply that names no path. It is `nil` when the ping failed,
so a failure is never mistaken for a path. The sample keeps the path and
turns a missing one into failure text:

```swift
      guard let result else { return .failure(Self.noReplyText) }
      if let path = result.path { return .reply(path: path, latencySeconds: result.latencySeconds) }
      return .failure("The daemon reported: \(result.error ?? "unknown error")")
```

and names each path as `tailscale ping` prints it:

```swift
  public static func describe(_ path: PingPath) -> String {
    switch path {
    case .direct(let endpoint): return "via \(endpoint)"
    case .peerRelay(let endpoint): return "via peer-relay(\(endpoint))"
    case .derp(let regionID, let code): return "via DERP(\(code ?? "region \(regionID)"))"
    case .unknown: return "by a path the daemon did not name"
    }
  }
```

## Run a bounded burst

A first ping often goes through DERP while the two nodes are still finding a
direct route; a second, a second later, may arrive directly. One reply is one
measurement. The sample therefore sends up to five disco pings one second
apart (the official CLI's spacing), gives each five seconds (its default
timeout), and stops at the first direct reply or the first failure:

```swift
    let policy = (max: PingBurstPolicy.maximumPings, spacing: PingBurstPolicy.spacing)
    for count in 1...policy.max {
      if count > 1 {
        do { try await environment.sleep(policy.spacing) } catch { return }
      }
      let reply = await pingOnce(daemon: daemon, ip: ip)
      guard token == burst, !Task.isCancelled else { return }
      let status: BurstStatus
      switch reply {
      case .reply(.direct, _): status = .stoppedAtDirect
      case .reply: status = count == policy.max ? .reachedMaximum : .inProgress
      case .failure: status = .failed
      }
```

Only a direct reply says which path the peer settled on. A burst that ends on
DERP or a peer relay is worded as what it is:

```swift
      switch status {
      case .stoppedAtDirect:
        return "Reached directly \(route)\(latencyText) after \(count)."
      case .inProgress:
        return "Ping \(pingsSent) went \(route)\(latencyText); still trying for a direct path."
      case .reachedMaximum, .failed:
        return "The last of \(count) went \(route)\(latencyText). This is one measurement, "
          + "not necessarily the path the peer will settle on."
      }
```

Each result keeps the time it was measured. The sample shows it as stale
after 30 seconds or as soon as the connection drops, and a later status
refresh never makes an old ping look new.

## Keep peers current

The sample opens one watch with ``TailscaleClient/watchIPNBusEvents(options:retryPolicy:bounds:onUndecodableLine:)``
and does not read peers out of notifications. It treats every notification,
every reconnect, and every reported gap as a reason to re-read
``TailscaleClient/status(query:)`` (debounced), and marks what it shows stale
while the watch is down:

```swift
  private func handle(_ event: IPNBusEvent, connectedBefore: inout Bool) {
    switch event {
    case .notification:
      notificationsReceived += 1
      scheduleRefresh()
    case .lifecycle(.connected):
      connection = .connected
      if connectedBefore { scheduleRefresh() }
      connectedBefore = true
    case .lifecycle(.stateGap):
      scheduleRefresh()
    case .lifecycle(.disconnected):
      connection = .disconnected
      markStale()
    case .lifecycle(.retrying(let attempt, _)):
      connection = .reconnecting(attempt: attempt)
      markStale()
    }
  }
```

That works on daemons before and after Tailscale 1.104, which stopped sending
the network map; <doc:RecipeMonitoring> explains why.

## See also

- <doc:RecipeMonitoring> — the same watch without a UI.
- <doc:RecipeTesting> — the mocks the sample's tests use.
- <doc:DiscoveryAndPermissions> — what the Mac App Store option asks macOS for.
