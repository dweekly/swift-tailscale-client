# Roadmap

**1.1.0 is the current release. It is for Mac developers who need to tell whether a peer is reachable through the user's existing Tailscale installation.** A backup app, for example, could show when it last reached the backup host, how the ping traveled, and when to try again. A successful peer ping describes the network path. The app still needs its own check for the backup service.

The supported runtime is macOS 13+. iOS, tvOS, and watchOS receive build checks. Linux is unqualified. Network Weather (NWX) supplied a real adapter smoke test for 1.0. See the [smoke test results](Documentation/releases/1.0.0.md#4-nwx-adapter-smoke--2026-09-19), [changelog](CHANGELOG.md), and [original 1.0 plan](Documentation/PLAN-1.0.md).

This unofficial, MIT-licensed package speaks LocalAPI directly from Swift. Tailscale’s Go client is the reference for daemon behavior. For an app that needs its own node identity, Tailscale provides an embedded Swift client. [Go client/local](https://pkg.go.dev/tailscale.com/client/local) · [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift)

## Try the released package

On a Mac with Swift 6.1 or later, start with a tagged checkout:

```sh
git clone --branch v1.1.0 --depth 1 https://github.com/dweekly/swift-tailscale-client.git
cd swift-tailscale-client
swift test --package-path Examples/Recipes --filter MockedClientTests/testStatusAgainstAFixture
```

The test reads a fixture and checks that the backend is running. It works without a Tailscale installation. For a live trial, start Tailscale on the Mac and run the following from the same checkout:

```sh
swift run --package-path Examples/StatusDemo StatusDemo
```

Look for the daemon version, backend state, and peer count. The demo also runs a STUN netcheck. Default discovery supports standalone Tailscale and local daemon sockets. Developers targeting the Mac App Store edition of Tailscale should review the opt-in discovery path and permission prompt. To use the library in an app, add the repository URL in Xcode and select the `TailscaleClient` product. [Integration guide](Documentation/INTEGRATING.md)

If a step fails, include the command, macOS version, Tailscale install method, and first unexpected result. Use placeholders for private peer details. [Report a trial failure](https://github.com/dweekly/swift-tailscale-client/issues/new?template=bug_report.yml)

## 1.1.0

1.1.0 contains what the [1.1.0 release plan](Documentation/PLAN-1.1.0.md) set out to build. The [changelog](CHANGELOG.md#110---2026-11-21) lists every change, and the [1.1.0 release record](Documentation/releases/1.1.0.md) says what was run to qualify it and what remains untested.

| Deliverable | What it is |
|---|---|
| **Peer Diagnostics**, a runnable SwiftUI example | `Examples/PeerDiagnostics` opens in fixture mode with a made-up tailnet, so it needs no Tailscale. **Live** reads the local daemon without changing it, lists peers, and shows how a ping reached the selected one, when it was measured, and whether it is still current. Its view model is a tested library target. |
| A ping-path API | `PingResult.path` returns `.direct`, `.peerRelay`, `.derp`, or `.unknown` with the official CLI's precedence, and `nil` for a failed ping. `tailscale-swift ping` prints the same classification. `isDirect` and `PingType.peerAPI` are corrected. |
| Watches on current daemons | Watches open on Tailscale 1.104 and later, report a rejection at once, stay open through quiet periods on loopback, and rediscover a daemon that restarted. |
| Inspectable evidence | Ping fixtures captured from a real daemon with provenance; an endpoint manifest that separates synthetic, source-checked, and live-observed evidence; and a script that runs disposable daemons of any upstream version. |

To try it from a checkout of the `v1.1.0` tag:

```sh
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics                    # window, fixture mode
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics --fixture --print  # headless, no Tailscale needed
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics --live --print     # headless, reads your daemon
swift test --package-path Examples/PeerDiagnostics
```

## Get it into developers' hands

Nothing in this section has happened for 1.1.0 yet: nobody has been invited and nothing has been posted. Ready to send are the `v1.1.0` tag, the fixture-mode command above, the sample's screenshot in its [README](Examples/PeerDiagnostics/README.md), and the [integration guide](Documentation/INTEGRATING.md).

1. **Before tagging**, invite a Mac diagnostics or remote-development app maintainer and a developer building a local preview or backup tool. Offer a short pairing session. Give each the same candidate commit SHA, a fixture-mode launch command, and one task in their own app. A fixed revision lets them retest exactly what failed. Lead with the sample and its screenshot in the README.
2. **Collect first-run feedback** in one GitHub trial issue. Ask which Mac and Tailscale variant they used, whether the caller was sandboxed, time to the first useful result, what surprised them, and whether they would keep the integration. Request a small integration diff if shareable. For failures, link a reproducible bug from the trial and ask the reporter to retry the fix. Keep hostnames, peer addresses, and credentials out of public reports. [Issue tracker](https://github.com/dweekly/swift-tailscale-client/issues)
3. **At release**, verify that Xcode resolves the tag, the sample runs from that tag, and Swift Package Index exposes the release and its docs. Share a short walkthrough on Swift Forums and submit the working example to Tailscale Community Projects with maintainer approval. Each post should point to the same trial instructions and feedback issue. The Homebrew tap is a second route for people who want to inspect their daemon before writing Swift. [Swift Package Index](https://swiftpackageindex.com/dweekly/swift-tailscale-client) · [Tailscale Community Projects](https://tailscale.com/community/community-projects) · [Homebrew tap](Documentation/HOMEBREW.md)
4. **A month after release**, publish the number of independent trials, successful first connections, and downstream apps using the tag, along with the most common blocker. Aim for two independent apps shipping the package. Treat the count as an adoption goal so the release can proceed on its technical merits.

## After the pilot

- **Status monitoring.** Keep freshness and resynchronization logic in the sample initially. If a second app needs it, extract a snapshot sequence with defined behavior across sleep, reconnect, profile change, and event loss.
- **Sharing a local preview with Serve.** Try one developer-tool integration. Detect an occupied route, use the existing conditional writes, and verify cleanup removes only the mapping created by the app.
- **Endpoint backlog.** Taildrop moves out of the proposed 1.1.0 scope. Revisit file transfer, Taildrive, and Tailnet Lock when a consumer can exercise the workflow. The stable upstream gaps include a bug-report recording handle and a duplex connection abstraction for `DialTCP` / `UserDial`. Track requests and rationale in the [coverage ledger](Documentation/LOCALAPI-COVERAGE.md).
- **Distribution.** Revisit homebrew-core once there is demand beyond the existing tap.

### Hardening

Follow-ups 1.1.0 surfaced, most important first. Each names what was observed.

1. **Live trials not yet run.** A logged-in Tailscale 1.104+ daemon with real peers, a real daemon restart, the Mac App Store edition, and a sandboxed caller have not been exercised live. Every 1.1.0 run on macOS used a logged-in 1.102.2 daemon or never-logged-in disposable daemons; the manual Headscale workflow on Linux logged a 1.104.7 daemon in, without peers ([release record](Documentation/releases/1.1.0.md)).
2. **Model the notification fields that replaced `NetMap`** (`SelfChange`, `InitialStatus`, peer deltas) after capturing them from a logged-in 1.104+ daemon. Today a peer-change notification decodes with no modelled field, so a consumer cannot tell it from any other notification.
3. **Suspended watches** (`NotifySuspendWhenBehind`, `resume-ipn-bus`) are unwrapped; upstream added them at the 152 pin ([COMPATIBILITY-152.md](Documentation/COMPATIBILITY-152.md)).
4. **Expose which discovery mechanism found the daemon.** `TailscaleClientConfiguration` gives the endpoint but not whether it came from an override, a socket, `libproc`, or the standalone app's port file; the Peer Diagnostics sample can only print the endpoint kind.
5. **An option to keep retrying the first watch open.** A failed first open throws while later drops retry, so an app that wants to wait for Tailscale to start has to loop itself.
6. **Unary rediscovery over loopback has no end-to-end test.** The refused-port path is covered only by error classification.
7. **The loopback watch's 7-day limit.** `URLSession.shared`'s `timeoutIntervalForResource` still ends a stream after 7 days; shown only with a 1.5-second session value.
8. **Scope the remembered obsolete-option rejection to the daemon, not the client.** After rediscovery lands on an older daemon, the client keeps omitting `.rateLimit` and `.initialNetMap` (harmless, since both are optional).
9. **Drop `.rateLimit` and `.initialNetMap` from `.default` and `.allInitial` in 2.0.** Current daemons reject them, and the client strips them on every such daemon.
10. **A too-long `TAILSCALE_LOCALAPI_SOCKET` reports "File name too long"** instead of an actionable message about the platform's Unix socket path limit (about 104 bytes on macOS).
11. **Refresh the manifest's live-evidence records from the integration lane automatically.** Today `evidence_lanes` and per-endpoint `live` records in `endpoints.json` are updated by hand; the check keeps them consistent with each other, not current.
12. **Seed the generative tests and record failing seeds.** The JSON round-trip generator is unseeded, so a failure cannot be replayed.
13. **An injectable clock for mock stream delays and retry backoff.** `MockTransport` delays and `StreamRetryPolicy` backoff use real time, so a consumer's reconnect test cannot use an injected clock.
14. **`attach-binaries.yml` attaches only the archive**, not the checksums or evidence file the release workflow publishes.
15. **Other loopback `URLError` codes.** Only `.cannotConnectToHost` counts as a connect-stage failure; `.cannotFindHost` and `.dnsLookupFailed` stay `networkFailure`, which matters only for a `.url` endpoint with a host name.
16. **A multi-line streaming error body is joined into one line** because it passes through the line framer.
17. **CLI parity for a DERP reply with no region code**: upstream prints `DERP()`, `tailscale-swift` prints `DERP(region <id>)`.
18. **Decide whether DCO sign-off is enforced.** `Scripts/check-governance.py` fails on most 1.1 commits and on every merge commit; nothing in CI runs it.
19. **Decide whether Linux gets a lane in required CI.** The package compiles and its unit suite passes in Swift 6.1 and 6.4 Linux containers, and the manual Headscale workflow passes on five daemon versions, but both run only by hand. A self-hosted Linux runner was deferred by the maintainer.
20. **Give hermetic runs a place in the endpoint manifest.** `endpoints.json` records live evidence from the macOS lane and historical evidence from the pre-1.0 matrix; a current Headscale run has only a lane record, so write endpoints that only that workflow exercises cannot show that they passed.
21. **Linux gaps found while reviving the build:** Thread Sanitizer does not run under Docker's default security profile, arm64 is untried, and `PeerDiagnosticsCore` imports Combine, so the sample's core does not build there.
22. **Docs deploy race.** `docc.yml` builds, uploads, and deploys in one job; twice on 2026-11-22 the deploy step read the Pages artifact in the same second it was uploaded and failed, and re-running the job cannot succeed ([#69](https://github.com/dweekly/swift-tailscale-client/issues/69)).
23. **Check the documentation index in CI.** Every tracked Markdown file has one entry in `README.md` or `Documentation/README.md` with a summary, a date, and an update trigger; `orphan-audit` checks this, but it runs only on the maintainer's machine, so a new document can land unindexed.

## Stability & Support Tiers

Upstream's own source says LocalAPI paths are namespaced under `/localapi/v0/` "to signal to people that they're not necessarily stable APIs." Additionally, since Tailscale 1.80+ the daemon is built from optional feature modules, so **endpoint availability depends on how tailscaled was compiled**, not just its version. This package answers with a three-tier policy, encoded in the API surface itself:

| Tier | Where it lives | Guarantee |
|------|----------------|-----------|
| **Stable** | Methods on `TailscaleClient` | SemVer-protected since 1.0. See the endpoint manifest for the evidence available for each method. |
| **Experimental** | `client.experimental` namespace | Compiles and works, but exempt from SemVer; tracks upstream churn (debug endpoints, log streaming, GUI push contract, self-update). May change or vanish in a minor release. |
| **Unsupported** | Documented only | Deliberately not wrapped, with the reason recorded in [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md). |

In accordance with DEC-5 (resolved in W7), strict source compatibility is enforced across all stable public symbols in `TailscaleClient` against baseline v1.0.0, with an empty breakage allowlist, via `Scripts/check-api-baseline.sh` and `APICompatibilityTests`. Upstream availability and Swift source compatibility remain separate promises.

"Complete coverage" means **every LocalAPI endpoint has a documented status** — implemented, planned, experimental, or unsupported-with-reason — not that every endpoint has a wrapper. Connection-hijacking endpoints (`dial`), alpha endpoints, and Tailscale-internal plumbing stay unsupported until there is a real use case.

The policy is mechanically enforced today: `Documentation/endpoints.json` records two independent stability axes per endpoint (Tailscale's own "API maturity" annotation and this package's Swift-support promise) plus the upstream feature gate, all pinned to an immutable `tailscale/tailscale` commit and re-verified against that commit's source in CI (`Scripts/verify-upstream-maturity.py`); generated tables and a contradiction check keep the human docs honest.

## API Conventions

Standing policy for all code:

- **Public memberwise initializers on every model**, so consumers can construct fixtures for SwiftUI previews and their own tests.
- **Tolerant enums**: string/int enums from the wire use an `.unknown(raw)`/`.other` case rather than failing decodes when upstream adds values. Booleans upstream marks `omitempty` decode absent-as-false, never as optional.
- **`Sendable` everywhere, `Equatable` on models**; `Encodable` where round-tripping matters.
- **Typed errors** with actionable `recoverySuggestion`s; every request gets a configurable deadline. Unary and streaming requests map HTTP response status to typed errors before returning data or events.
- **Streaming resilience**: an undecodable line in a stream is skipped and surfaced through a reporting hook, never fatal to the stream. Reconnection with exponential backoff is an explicit opt-in.
- **Safe configuration updates**: `ServeConfig` preserves unmodeled fields losslessly, read-modify-write requires concurrency snapshots (`ServeConfigSnapshot`) and conditional updates by default, with an explicit unconditional replacement operation (`replaceServeConfigUnconditionally`).
- **Naming follows Go `client/local`** adapted to Swift conventions — including upstream's `NetworkLock` → `TailnetLock` rename and `switchToEmptyProfile()` (`addProfile()` removed).
- **Secrets never reach diagnostic surfaces** — not logs, not `description`, not reflection; regression tests assert no substring of an injected secret escapes.

## Development Practice: Spike Before You Ship

No endpoint is implemented from documentation alone. Every new surface follows the same sequence:

1. **Spike against a real daemon.** Exercise the endpoint with `curl --unix-socket` (or a throwaway Swift scratch file) against an actual running tailscaled — locally and/or in the headscale integration environment — and observe real request/response shapes, headers, status codes, and streaming behavior.
2. **Cross-check upstream source at the pinned commit.** The authority is `tailscale/tailscale`: the handler in `ipn/localapi/`, the Go client method in `client/local/`, and the types in `tailcfg`/`ipn`. Public docs lag the code; the code decides field names, optionality, and edge behavior. Record the symbol, maturity, and gate in `endpoints.json` — CI verifies all three against the pinned revision.
3. **Capture fixtures from the spike.** Real (sanitized) responses become the versioned fixtures the unit tests decode — not hand-typed JSON guessed from docs.
4. **Then implement**, with the fixtures and the spike findings encoding the corner cases (empty bodies, 204s/201s, ETags, chunked framing) into tests before the API is considered done.

The spike workflow is documented in [`Documentation/TESTING.md`](Documentation/TESTING.md). Ping replies are captured from a real daemon, sanitized, and recorded with provenance by `Scripts/capture-ping-fixture.py`.

## Contributing to the roadmap

Describe the feature you want to ship, the Mac and Tailscale installation you expect to support, and the smallest example that would let you try it. [Request an endpoint or report a problem](https://github.com/dweekly/swift-tailscale-client/issues/new/choose)
