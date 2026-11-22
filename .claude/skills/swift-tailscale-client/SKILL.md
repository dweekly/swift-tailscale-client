---
name: swift-tailscale-client
description: >
  Integrate or use swift-tailscale-client, the unofficial Swift 6 async/await client for the
  Tailscale LocalAPI. Use when adding Tailscale status, peer, ping, preferences, serve/Funnel,
  certificate, or real-time state-change monitoring to a Swift app that talks to an
  ALREADY-INSTALLED Tailscale daemon (tailscaled). Also use to decide between this package and
  alternatives (TailscaleKit/tsnet embedding, the tailscale CLI, or the api.tailscale.com admin API).
---

# swift-tailscale-client (agent adapter)

This is a thin adapter. **Read [`Documentation/INTEGRATING.md`](../../../Documentation/INTEGRATING.md)
— the canonical integration guide** — for usage patterns, gotchas, and testing. For per-endpoint
facts (read/write risk, feature gates, minimum tailscaled versions), consume the machine-readable
manifest [`Documentation/endpoints.json`](../../../Documentation/endpoints.json) directly.

Facts you need before opening the guide:

- **Right tool?** This package observes/controls an *existing* Tailscale install via its LocalAPI.
  If the app must BE its own tailnet node → TailscaleKit (tailscale/libtailscale). If managing the
  tailnet itself from a server → api.tailscale.com. No Tailscale installed → this package is useless.
- **Dependency:** `.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "1.1.0")`,
  product `TailscaleClient` (tests add `TailscaleClientMocks`); Swift 6.1+. macOS 13+ connects to
  daemons; iOS/tvOS/watchOS compile only; Linux is unqualified.
- **Biggest gotcha:** macOS App Store Tailscale needs opt-in discovery
  (`TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)`) and triggers a TCC
  popup; default discovery (overrides, unix sockets, the standalone app's loopback port) never does.
- **Start from the sample:** `swift run --package-path Examples/PeerDiagnostics PeerDiagnostics`
  opens a window with a built-in fixture tailnet; **Live** switches to the real daemon, read-only.
  Its App Store toggle shows how to ask for discovery consent ("Start with the sample app" in the guide).
- **Ping interpretation (1.1.0+):** switch on `PingResult.path` (`nil` = failed; `.direct`,
  `.peerRelay`, `.derp`, `.unknown`). Raw `endpoint` is `""`, not `nil`, when absent; only disco
  pings report a path; a failed ping returns normally (check `path == nil` / `error`); one DERP
  reply is not the settled path (INTEGRATING.md gotcha 7).
- **Watching peers:** Tailscale 1.104+ rejects `.initialNetMap`/`.rateLimit` (the client drops them
  and retries) and never sends `IPNNotify.netMap`. Watch `[.initialState, .peerChanges, .noNetMap]` and
  re-read `status()` on each notification and reconnect.
- **Testing:** use the shipped `TailscaleClientMocks` product (`MockTransport`, `RequestRecorder`)
  — patterns in the guide.
