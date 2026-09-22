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

- The upstream verifier passes: 52 endpoint symbols, 42 gates, 20 unwrapped
  handlers, the stable-gap ledger, and capability 148 agree with the pin.
- All 17 request-contract tests pass locally, including the default value,
  request-header overrides, environment overrides, and version diagnostics.
- Generated documentation, release consistency, recipe snippets, and
  changed-file Swift formatting checks pass.
- [Read-only macOS daemon integration](https://github.com/dweekly/swift-tailscale-client/actions/runs/35675311377)
  passed for re-pin commit `53bd247fcedb5d8f5ce01909783463bc1fd91df8`.
- Required Apple CI and read-only macOS integration must also pass on the
  final PR revision before merge. iOS/tvOS/watchOS lanes validate builds;
  macOS is the supported runtime.

An initial optional Linux matrix attempt stopped at a pre-existing Linux
compile error. A subsequent attempt was canceled, and its Linux-specific
changes were reverted. Neither run provides compatibility evidence. Linux
is unqualified and is not a gate for this re-pin.
