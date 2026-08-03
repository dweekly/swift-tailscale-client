# Copilot instructions for swift-tailscale-client

Read `Documentation/INTEGRATING.md` — the canonical integration guide — before
suggesting code that uses this package. Per-endpoint capabilities, risk levels,
feature gates, and minimum tailscaled versions are machine-readable in
`Documentation/endpoints.json`.

Key constraints for suggestions:

- This package connects to an already-installed tailscaled via the LocalAPI; it
  never embeds a node. Swift 6 strict concurrency, async/await only.
- Writes: `editPrefs(_:)` patches only the `MaskedPrefs` fields that were set;
  `setServeConfig(_:)` replaces the whole config — always snapshot with
  `serveConfig()` first and retry on `.preconditionFailed`.
- Prefer `watchIPNBus(...)` streaming over status polling.
- Tests should inject `MockTransport` from the `TailscaleClientMocks` product,
  never hit a real daemon.
- For work on this repo itself, follow `CLAUDE.md` (build/test commands,
  formatting via swift-format, 100-column limit).
