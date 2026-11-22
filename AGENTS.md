# Agent guide for swift-tailscale-client

**Canonical integration documentation: [`Documentation/INTEGRATING.md`](Documentation/INTEGRATING.md).**
Per-endpoint facts (Swift symbol, read/write risk, feature gate, minimum/tested
tailscaled versions, stability tier) are machine-readable in
[`Documentation/endpoints.json`](Documentation/endpoints.json) — prefer the JSON
over scraping tables.

Quick orientation:

- This package talks to an **already-installed** tailscaled via the LocalAPI.
  It is not an embedded Tailscale node (that's TailscaleKit) and not the
  api.tailscale.com admin API.
- Dependency: `.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "1.1.0")`,
  product `TailscaleClient`. Test with the `TailscaleClientMocks` product.
- Start from the sample: `swift run --package-path Examples/PeerDiagnostics PeerDiagnostics`
  (fixture mode, no Tailscale needed; **Live** is an explicit, read-only switch). It shows
  every pattern below; see "Start with the sample app" in INTEGRATING.md.
- Ping path (1.1.0+): read `PingResult.path` (`.direct`, `.peerRelay`, `.derp`,
  `.unknown`; `nil` on error), not raw `endpoint`; only disco pings report a path,
  and one reply is one measurement (INTEGRATING.md gotcha 7).
- Upgrading from 1.0: compiles unchanged; `isDirect` is now `true` only for a direct disco
  path, and on 1.104+ no `NetMap` arrives ("Upgrading from 1.0" in INTEGRATING.md).
- IPN bus watches: Tailscale 1.104+ rejects `.initialNetMap`/`.rateLimit` and sends no netmap;
  the client drops those options automatically. Follow peers with `[.initialState, .peerChanges, .noNetMap]`
  and re-read `status()` per notification (details in INTEGRATING.md, gotcha 4).
- Release scope: macOS 13+ runtime; iOS/tvOS/watchOS build only. Linux is unqualified and not part of required CI.

Working **on** this repository (not just consuming it): build/test commands and
architecture conventions are in [`CLAUDE.md`](CLAUDE.md); endpoint coverage
policy in [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md);
the spike-first development practice in [`Documentation/TESTING.md`](Documentation/TESTING.md).
