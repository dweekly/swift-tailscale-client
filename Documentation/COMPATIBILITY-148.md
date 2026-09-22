# Capability 148 compatibility review

This re-pin addresses [issue #39](https://github.com/dweekly/swift-tailscale-client/issues/39).
The default request header advances from `Tailscale-Cap: 144` to `148`.
Explicit configuration and the environment override retain their behavior.

## Upstream review

Reviewed immutable commit
[`7bf76690f09db74b1f48d49db056fac69c4b421e`](https://github.com/tailscale/tailscale/tree/7bf76690f09db74b1f48d49db056fac69c4b421e)
on 2026-09-21.

- The provenance verifier reports no maturity, feature-gate, or inventory
  changes among the handlers it scans. Only the capability constant changes.
- `tailcfg/tailcfg.go` records four additions since 144: scoped Quad100 on
  macOS (145), connection-rejection diagnostics (146), control-plane retry
  handling (147), and `Node.StableTailnetID` (148).
- A source search across that revision finds `Tailscale-Cap` only in the Go
  client's request-header construction and the LocalAPI response-header
  construction. There is no request-header capability gate to cross in this
  revision. This package connects to a daemon; it does not implement the
  daemon's control-plane protocol. The additions therefore require no new
  Swift LocalAPI wire models for this re-pin.
- Historical captured fixtures retain their original capability metadata.
  This review does not expand endpoint coverage or qualify Linux support.

## Validation

The re-pin must pass the upstream verifier, capability contract tests,
required Apple CI, read-only macOS daemon integration, and the manual
hermetic daemon matrix before merge. Run links and outcomes will be recorded
here when those checks finish.
