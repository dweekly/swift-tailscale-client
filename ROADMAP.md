# Roadmap

**1.0.0 is available. We propose 1.1.0 for Mac developers who need to tell whether a peer is reachable through the user's existing Tailscale installation.** A backup app, for example, could show when it last reached the backup host, how the ping traveled, and when to try again. A successful peer ping describes the network path. The app still needs its own check for the backup service.

The supported runtime is macOS 13+. iOS, tvOS, and watchOS receive build checks. Linux is unqualified. Network Weather (NWX) supplied a real adapter smoke test for 1.0. See the [smoke test results](Documentation/releases/1.0.0.md#4-nwx-adapter-smoke--2026-09-19), [changelog](CHANGELOG.md), and [original 1.0 plan](Documentation/PLAN-1.0.md).

This unofficial, MIT-licensed package speaks LocalAPI directly from Swift. Tailscale’s Go client is the reference for daemon behavior. For an app that needs its own node identity, Tailscale provides an embedded Swift client. [Go client/local](https://pkg.go.dev/tailscale.com/client/local) · [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift)

## Try the released package

On a Mac with Swift 6.1 or later, start with a tagged checkout:

```sh
git clone --branch v1.0.0 --depth 1 https://github.com/dweekly/swift-tailscale-client.git
cd swift-tailscale-client
swift test --package-path Examples/Recipes --filter MockedClientTests/testStatusAgainstAFixture
```

The test reads a fixture and checks that the backend is running. It works without a Tailscale installation. For a live trial, start Tailscale on the Mac and run the following from the same checkout:

```sh
swift run --package-path Examples/StatusDemo StatusDemo
```

Look for the daemon version, backend state, and peer count. The demo also runs a STUN netcheck. Default discovery supports standalone Tailscale and local daemon sockets. Developers targeting the Mac App Store edition of Tailscale should review the opt-in discovery path and permission prompt. To use the library in an app, add the repository URL in Xcode and select the `TailscaleClient` product. [Integration guide](Documentation/INTEGRATING.md)

If a step fails, include the command, macOS version, Tailscale install method, and first unexpected result. Use placeholders for private peer details. [Report a trial failure](https://github.com/dweekly/swift-tailscale-client/issues/new?template=bug_report.yml)

## Proposed 1.1.0

The [1.1.0 release plan](Documentation/PLAN-1.1.0.md) defines the test cases, live Mac trials, documentation checks, and evidence the maintainer reviews before tagging.

| Deliverable | How to decide it is ready |
|---|---|
| **Peer Diagnostics**, a runnable SwiftUI example | A fresh checkout opens in fixture mode and shows a peer and its last ping. The user can choose live mode, select a peer, and see the measured path and time. Show offline, stale, and unavailable states. Start the watcher at launch and refresh after a stream gap or profile change. Test the same transitions with `TailscaleClientMocks`. |
| An additive ping-path API | Prototype a typed result for direct, peer-relayed, DERP-relayed, and unknown paths. Match the official CLI's precedence when a reply has multiple fields. Exercise it in both the sample and the bundled CLI. Keep the raw fields and existing source compatibility. [Official ping implementation](https://github.com/tailscale/tailscale/blob/main/cmd/tailscale/cli/ping.go) |
| First-launch discovery evidence | Run the live macOS example with endpoint and credential overrides cleared. Start with standalone Tailscale. Publish observed results for standalone, App Store, and Unix-socket installations, identifying the caller's sandbox status, prompt, failure, and recovery. Mark untried combinations explicitly. A passing shell-configured run only establishes connectivity. |
| Compatibility evidence developers can inspect | Exercise status, ping, and watch on a named daemon version. Compare sanitized results with the official CLI or pinned Go client. Label real captures and synthetic fixtures. Reconcile the support and adoption guides with the actual platform checks and NWX evidence. Triage the upstream drift report, including what suspended watches mean for recovery. [Drift issue #45](https://github.com/dweekly/swift-tailscale-client/issues/45) |

**Release decision.** Ship 1.1.0 when the additive API works in both callers, the example passes a fresh-checkout trial, and the release commit passes the existing Apple CI, API compatibility, and read-only macOS integration checks. Include a screenshot, the exact trial commands, and the tested environments in the release notes. If the trials produce only bug fixes and documentation, use the next 1.0.x patch for those changes. The maintainer tags the tested commit using the [release procedure](Documentation/RELEASING.md).

## Get it into developers' hands

1. **Before tagging**, invite a Mac diagnostics or remote-development app maintainer and a developer building a local preview or backup tool. Offer a short pairing session. Give each the same candidate commit SHA, a fixture-mode launch command, and one task in their own app. A fixed revision lets them retest exactly what failed. Lead with the sample and its screenshot in the README.
2. **Collect first-run feedback** in one GitHub trial issue. Ask which Mac and Tailscale variant they used, whether the caller was sandboxed, time to the first useful result, what surprised them, and whether they would keep the integration. Request a small integration diff if shareable. For failures, link a reproducible bug from the trial and ask the reporter to retry the fix. Keep hostnames, peer addresses, and credentials out of public reports. [Issue tracker](https://github.com/dweekly/swift-tailscale-client/issues)
3. **At release**, verify that Xcode resolves the tag, the sample runs from that tag, and Swift Package Index exposes the release and its docs. Share a short walkthrough on Swift Forums and submit the working example to Tailscale Community Projects with maintainer approval. Each post should point to the same trial instructions and feedback issue. The Homebrew tap is a second route for people who want to inspect their daemon before writing Swift. [Swift Package Index](https://swiftpackageindex.com/dweekly/swift-tailscale-client) · [Tailscale Community Projects](https://tailscale.com/community/community-projects) · [Homebrew tap](Documentation/HOMEBREW.md)
4. **A month after release**, publish the number of independent trials, successful first connections, and downstream apps using the tag, along with the most common blocker. Aim for two independent apps shipping the package. Treat the count as an adoption goal so the release can proceed on its technical merits.

## After the pilot

- **Status monitoring.** Keep freshness and resynchronization logic in the sample initially. If a second app needs it, extract a snapshot sequence with defined behavior across sleep, reconnect, profile change, and event loss.
- **Sharing a local preview with Serve.** Try one developer-tool integration. Detect an occupied route, use the existing conditional writes, and verify cleanup removes only the mapping created by the app.
- **Endpoint backlog.** Taildrop moves out of the proposed 1.1.0 scope. Revisit file transfer, Taildrive, and Tailnet Lock when a consumer can exercise the workflow. The stable upstream gaps include a bug-report recording handle and a duplex connection abstraction for `DialTCP` / `UserDial`. Track requests and rationale in the [coverage ledger](Documentation/LOCALAPI-COVERAGE.md).
- **Distribution.** Revisit homebrew-core once there is demand beyond the existing tap.

## Stability & Support Tiers

Upstream's own source says LocalAPI paths are namespaced under `/localapi/v0/` "to signal to people that they're not necessarily stable APIs." Additionally, since Tailscale 1.80+ the daemon is built from optional feature modules, so **endpoint availability depends on how tailscaled was compiled**, not just its version. This package answers with a three-tier policy, encoded in the API surface itself:

| Tier | Where it lives | Guarantee |
|------|----------------|-----------|
| **Stable** | Methods on `TailscaleClient` | SemVer-protected since 1.0. See the endpoint manifest for the evidence available for each method. |
| **Experimental** | `client.experimental` namespace | Compiles and works, but exempt from SemVer; tracks upstream churn (debug endpoints, log streaming, GUI push contract, self-update). May change or vanish in a minor release. |
| **Unsupported** | Documented only | Deliberately not wrapped, with the reason recorded in [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md). |

In accordance with DEC-5 (resolved in W7), strict source compatibility is enforced across all stable public symbols in `TailscaleClient` against baseline v0.12.0 via `Scripts/check-api-baseline.sh` and `APICompatibilityTests`. Upstream availability and Swift source compatibility remain separate promises.

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

The spike workflow is documented in [`Documentation/TESTING.md`](Documentation/TESTING.md). Versioned fixture-capture tooling and provenance are implemented via `Scripts/capture-fixtures.py` (W5).

## Contributing to the roadmap

Describe the feature you want to ship, the Mac and Tailscale installation you expect to support, and the smallest example that would let you try it. [Request an endpoint or report a problem](https://github.com/dweekly/swift-tailscale-client/issues/new/choose)
