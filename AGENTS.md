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
- Dependency: `.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.10.0")`,
  product `TailscaleClient`. Test with the `TailscaleClientMocks` product.
- macOS 13+/Linux connect to real daemons; iOS/tvOS/watchOS build only.

Working **on** this repository (not just consuming it): build/test commands and
architecture conventions are in [`CLAUDE.md`](CLAUDE.md); endpoint coverage
policy in [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md);
the spike-first development practice in [`Documentation/TESTING.md`](Documentation/TESTING.md).
