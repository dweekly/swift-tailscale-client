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
- **Dependency:** `.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.12.0")`,
  product `TailscaleClient`. macOS 13+/Linux connect to daemons; iOS/tvOS/watchOS compile only.
- **Biggest gotcha:** macOS App Store Tailscale needs opt-in discovery
  (`TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)`) and triggers a TCC
  popup; default unix-socket discovery never does.
- **Testing:** use the shipped `TailscaleClientMocks` product (`MockTransport`, `RequestRecorder`)
  — patterns in the guide.
