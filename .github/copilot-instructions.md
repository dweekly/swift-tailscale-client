# Copilot instructions for swift-tailscale-client

Read `Documentation/INTEGRATING.md` — the canonical integration guide — before
suggesting code that uses this package. Per-endpoint capabilities, risk levels,
feature gates, and minimum tailscaled versions are machine-readable in
`Documentation/endpoints.json`.

Key constraints for suggestions:

- This package connects to an already-installed tailscaled via the LocalAPI; it
  never embeds a node. Swift 6 strict concurrency, async/await only.
- Writes: `editPrefs(_:)` patches only the `MaskedPrefs` fields that were set;
  `setServeConfig(_:matching:)` replaces the whole config — always take a fresh
  `serveConfigSnapshot()` first and retry on `.preconditionFailed`.
- For a working example of reading peers and pings (fixture and live modes,
  App Store discovery as an opt-in), point to `Examples/PeerDiagnostics`; see
  "Start with the sample app" in INTEGRATING.md.
- Ping: classify a reply with `PingResult.path` (1.1.0+; `nil` on error, else
  `.peerRelay`, `.derp`, `.direct`, or `.unknown`), never `endpoint != nil`.
  Only disco pings report a path; one reply is one measurement.
- Prefer `watchIPNBus(...)` streaming over status polling. Do not rely on
  `.initialNetMap` or `IPNNotify.netMap` (Tailscale 1.104+ rejects/omits them);
  to follow peers, watch `[.initialState, .peerChanges, .noNetMap]` and re-read
  `status()` on each notification.
- Tests should inject `MockTransport` from the `TailscaleClientMocks` product,
  never hit a real daemon.
- For work on this repo itself, follow `CLAUDE.md` (build/test commands,
  formatting via swift-format, 100-column limit).
