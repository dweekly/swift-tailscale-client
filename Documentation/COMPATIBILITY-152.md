# Capability 152 compatibility review

This re-pin addresses [issue #45](https://github.com/dweekly/swift-tailscale-client/issues/45).
The default request header advances from `Tailscale-Cap: 148` to `152`.
Explicit configuration and the environment override retain their behavior.

The review also found that current Tailscale releases reject two IPN bus
watch options this package sends by default. That contract change is
independent of the capability number and is described under
[Findings](#findings-ipn-bus-watch-contract); it is not fixed by this re-pin.

## Upstream review

Reviewed immutable commit
[`1db8e79a8b00d9ea3a7459c92df07e3d565a8811`](https://github.com/tailscale/tailscale/tree/1db8e79a8b00d9ea3a7459c92df07e3d565a8811)
(the head of `main` on 2026-11-21) against the previous pin
`7bf76690f09db74b1f48d49db056fac69c4b421e`, 437 commits apart. Line numbers
below are at the new pin.

### Capability versions

`tailcfg/tailcfg.go:200-204` records four additions since 148:

| Version | Upstream meaning | Effect on a LocalAPI client advertising it |
|---|---|---|
| 149 | Sentinel asking the control server to send `NodeAttrCacheNetworkMaps` enabled | None: control-plane negotiation between tailscaled and its control server |
| 150 | Client handles app connectors with `"mode": "magicip"` as conn25 | None: tailscaled's own app-connector handling |
| 151 | Client understands `nodecap.LogUploadAuth` for authenticated log uploads | None: tailscaled's log uploader |
| 152 | Client supports hybrid post-quantum handshakes | None: tailscaled's WireGuard handshakes |

At this revision the daemon never reads the `Tailscale-Cap` request header.
The only uses of the header name outside tests are the Go client setting it
on requests (`client/local/local.go:170`) and the LocalAPI setting it on
responses (`ipn/localapi/localapi.go:256`). The advertised number therefore
does not change daemon behavior toward this package for any endpoint,
including `watch-ipn-bus`.

### New handlers

Both are recorded in `unwrapped_upstream_handlers`. Neither is in a tagged
Tailscale release as of this review (`git tag --contains` is empty for both
introducing commits; the newest release tag is `v1.104.7`).

- `cert-status/` (gate `HasACME`, `ipn/localapi/cert.go:23-29`): read-only
  status of a cached TLS certificate, reporting a cache miss as
  `Missing: true` instead of starting issuance. The Go client method
  `CertStatus` (`client/local/cert.go:144-166`) is annotated not stable and
  maps 404 to `ErrCertStatusUnsupported`. Introduced in `a986bbfac`.
- `resume-ipn-bus` (gate `HasIPNBus`, `ipn/localapi/localapi.go:127`,
  handler at `:931-947`): `POST ?session=<SessionID>` resumes a
  `watch-ipn-bus` session that tailscaled suspended. The Go client method
  `ResumeIPNBus` (`client/local/local.go:1541-1551`) is annotated not
  stable. Introduced in `b706df603`.

### Suspended watches

Suspension is opt-in and does not apply to this package's watches.

- Only a watcher whose mask includes `NotifySuspendWhenBehind` (bit 19,
  `ipn/backend.go:214-227`) can be suspended. That bit requires
  `NotifyInitialState` (`ipn/backend.go:316-322`). This package's
  `NotifyWatchOpt` defines bits 0 through 10 and never sets bit 19.
- When a watcher's queue is full, tailscaled picks one of three outcomes by
  mask (`ipn/ipnlocal/local.go:4409-4428`): block until it drains
  (`NotifyInProcessNoDisconnect`, in-process only), suspend
  (`NotifySuspendWhenBehind`), or, for every other watcher including this
  package's, send one final `Notify` with `ErrMessage` set to
  `IPN bus consumer fell behind; closing watch` and close the stream
  (`ipn/ipnlocal/local.go:3960`, `:4451-4460`). The close-on-lag behavior
  predates the previous pin (`edcc2c94d`, 2026-06-08).
- A suspended watcher receives exactly one `Notify` with `Suspended: true`
  and then silence on an open stream until `resume-ipn-bus`
  (`ipn/ipnlocal/local.go:4462-4475`). `LocalBackend.SuspendWatchNotifications`
  (`:4159-4170`) refuses sessions that did not request bit 19, and it has no
  non-test caller.

An ordinary `watchIPNBus` consumer therefore cannot stall waiting for a
resume. `Notify.Suspended` and `NodeGUIVisibility` are new optional fields;
tolerant decoding ignores them.

### Wire types for wrapped endpoints

- Status (`ipn/ipnstate/ipnstate.go`): tailnet-lock key fields change Go
  type from `key.NLPublic` to `key.TLPublic`, a rename whose JSON text form
  keeps the `nlpub:` prefix (`types/key/tl.go:28`). This package does not
  model those fields. `PeerStatus.IsConn25Connector` is a Go-only helper.
- Prefs (`ipn/prefs.go`): adds `Tailnet` and `TailnetSet` (both `omitzero`).
  Tolerant decoding ignores the new key. Unverified: whether `editPrefs`
  needs `TailnetSet` for any caller; no current API sends it.
- Serve (`ipn/serve.go`): a build-feature guard only; no JSON change.
- Ping: no change to `ipnstate.PingResult` in this range.
- Notify (`ipn/backend.go`): adds `Suspended` (`:357`) and
  `NodeGUIVisibility` (`:400`); adds watch bit `NotifySuspendWhenBehind`
  (bit 19). No bit or field was removed between the two pins.

## Findings: IPN bus watch contract

These changes predate the previous pin and are present at this one. They
are independent of the capability number.

- `ipn.ValidateNotifyWatchOpt` (`ipn/backend.go:309-325`) rejects
  `ObsoleteNotifyRateLimit` (bit 8) and `ObsoleteNotifyInitialNetMap`
  (bit 3), and `serveWatchIPNBus` answers HTTP 400 with that message before
  streaming (`ipn/localapi/localapi.go:910-911`). Introduced by `1b0f7b3c6`
  and `ab4262680` (2026-09-11); first release tag `v1.104.0`
  (2026-09-30); not in `v1.102.2`.
- The same commits removed `Notify.NetMap`. Watchers seed from
  `NotifyInitialStatus` (bit 14, `Notify.InitialStatus`), follow
  `Notify.SelfChange`, and opt into peer deltas with `NotifyPeerChanges`
  (bit 12) and `NotifyPeerPatches` (bit 15). `SelfChange` and
  `InitialStatus` already exist in `v1.102.2`.
- This package sends bit 8 in `NotifyWatchOpt.default` and in every
  `tailscale-swift watch` invocation, and bit 3 in `.allInitial`, the
  monitoring recipe (`Examples/Recipes/Sources/Recipes/MonitorChanges.swift`,
  `RecipeMonitoring.md`), and `watch --all-initial`. `IPNNotify` decodes
  `NetMap` but none of `SelfChange`, `InitialStatus`, `PeersChanged`,
  `PeersRemoved`, or `PeerChangedPatch`.
- From source reading (unverified against a v1.104 daemon): on Tailscale
  v1.104.0 or later, a watch with the default options fails with HTTP 400,
  which this package reports as `unexpectedStatus(400, …)`.
  `StreamRetryPolicy` classifies that status as retryable, so a watch with
  a reconnect policy would retry the rejected request instead of failing.

## Validation

Local evidence: this Mac, macOS 27.2.1 (26B131), standalone Tailscale
1.102.2 (`tailscale commit 6cac918179d4`), backend Running on a real
tailnet, 2026-11-21. Sanitized summaries (top-level JSON keys and timing
only) are kept outside the repository with the PR's working notes.

- `tailscale-swift watch -j -e` (exactly `NotifyWatchOpt.default`) for 200 s:
  the stream opened, the first message carried `Health`, `SessionID`, and
  `State`, and 67 engine updates followed through the end of the window
  with no gap over 3.1 s, no `ErrMessage`, and no early end. The CLI prints
  the decoded model, so fields this package does not model (such as
  `Suspended`) would not appear in this output.
- `tailscale-swift watch -j --all-initial` (bits 0-8 except 4, plus 10) for
  60 s: the stream opened, the first message carried `Health`, `NetMap`,
  `Prefs`, `SessionID`, `State`, and `SuggestedExitNode`, and 21 messages
  arrived with no gap over 4.7 s and no `ErrMessage`.
- `TAILSCALE_INTEGRATION=1 swift test --filter TailscaleClientIntegrationTests`:
  44 tests, 39 passed, 5 skipped (4 write tests that require
  `TAILSCALE_INTEGRATION_WRITE`, and netcheck with no STUN responses),
  0 failures. This suite does not open an IPN bus watch.
- `swift run --package-path Examples/StatusDemo StatusDemo`: connected,
  reported backend state running, 11 peers, and 18 optional daemon
  features. Netcheck reported no STUN responses.
- The upstream verifier passes against the new pin with no drift: 52
  endpoint symbols, 42 gates, 22 unwrapped handlers, the stable-gap ledger,
  and capability 152.
- Unit tests, generated documentation, release consistency, model
  conformance, API baseline, and strict formatting checks pass. The
  commands and results are in the PR body.

Unverified:

- Behavior against a Tailscale v1.104 or later daemon. This daemon predates
  the watch-option rejection, so the local runs above do not exercise it.
- Required Apple CI and read-only macOS integration on the final PR
  revision must pass before merge. Linux is unqualified and is not a gate.
