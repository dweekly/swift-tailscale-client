# Roadmap

This roadmap describes what remains between the current release and a complete, rigorously tested, well-documented 1.0 — and what "complete" means for a client of an API that Tailscale itself labels unstable. Shipped work lives in [`CHANGELOG.md`](CHANGELOG.md); this document tracks only what is yet to be done.

**Detailed 1.0 execution plan:** [`Documentation/PLAN-1.0.md`](Documentation/PLAN-1.0.md) defines the implementation sequence, design decisions, acceptance tests, consumer validation, and release evidence required by the checklist below. It is a plan, not a claim that those guarantees already ship.

`swift-tailscale-client` is an unofficial, MIT-licensed project with no affiliation to Tailscale Inc.

## Philosophy & Positioning

This package connects to an **existing `tailscaled` daemon** and speaks its LocalAPI. It is the Swift equivalent of Tailscale's own Go [`client/local`](https://pkg.go.dev/tailscale.com/client/local) package: control and observe the Tailscale installation the user already has.

That distinguishes it from [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift) and other tsnet-based packages, which **embed a second Tailscale node** inside your app. Both are valid; they solve different problems. As of mid-2026 this is the only Swift package in the LocalAPI niche.

**Primary driver:** the Network Weather (NWX) macOS diagnostics app. The roadmap favors read-heavy monitoring and diagnostics first, configuration and management second, and specialized surfaces (Taildrop, Taildrive, Tailnet Lock) after 1.0.

## Stability & Support Tiers

Upstream's own source says LocalAPI paths are namespaced under `/localapi/v0/` "to signal to people that they're not necessarily stable APIs." Additionally, since Tailscale 1.80+ the daemon is built from optional feature modules, so **endpoint availability depends on how tailscaled was compiled**, not just its version. This package answers with a three-tier policy, encoded in the API surface itself:

| Tier | Where it lives | Guarantee |
|------|----------------|-----------|
| **Stable** | Methods on `TailscaleClient` | SemVer-protected once 1.0 ships. Covered by unit + integration tests on every supported tailscaled version. |
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
- **Typed errors** with actionable `recoverySuggestion`s; every request gets a configurable deadline. Typed status mapping, `Tailscale-Version` observation, and audit-reason injection apply to unary requests (streaming is documented as `.transport`-only).
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

## Version Plan (remaining)

v0.4.0 through v0.12.0 have shipped; their contents are recorded in [`CHANGELOG.md`](CHANGELOG.md). What remains:

| Version | Theme | New endpoints | Key non-feature work |
|---------|-------|---------------|----------------------|
| **Pre-1.0 / RC** | Reliability and compatibility | — | Safe writes; transport/streaming guarantees; native discovery; exact-commit evidence; consumer evaluation |
| **v1.0.0** | API freeze | — | All release gates below; approved API baseline, support policy, and consumer migrations |
| **v1.1** | Taildrop | `file-put/`, `files/` (incl. long-poll), `file-targets` | Upload/download progress via IPN bus |
| **v1.2** | Taildrive | `drive/fileserver-address`, `drive/shares` CRUD | |
| **v1.3** | Tailnet Lock | 13 `tka/*` endpoints (`TailnetLock` naming) | |
| **Post-1.0 (additive)** | Stable-gap ledger | `BugReportWithOpts` recording handle; `DialTCP`/`UserDial` duplex abstraction | Both tracked in the coverage ledger; see below |
| **Ongoing** | Experimental debug surface | `debug` actions, `pprof`, `update/install|progress`, `appc-route-info`, `policy/*`, `debug-bus-*`, `prefs/service-clients` | Added on demand; never SemVer-bound |

## v1.0.0 — API Freeze

**Existing foundations:** the pinned handler inventory, 85% line-coverage floor, public mocks, automated multi-version Linux Headscale matrix, macOS integration lane, tutorial/examples, and distribution automation have shipped.

**Release gates:** tracked via `aggregate-release-evidence.py` and `Documentation/PLAN-1.0.md`:

- [x] **G1 Safe writes:** lossless Serve updates, conditional snapshots, explicit unconditional replacement, preference-write audit, disposable-daemon mutation evidence. (M1)
- [x] **G2 Transport:** correct framing, finite resource limits, interruptible connect/write/read operations, resource cleanup, adversarial/property tests. (M1)
- [x] **G3 Monitoring:** bounded queues, observable gaps/overflow, consistent streaming response errors/metadata, classified retries, cancellation and soak evidence. (M1)
- [x] **G4 Discovery:** native library discovery for supported macOS installation flavors and Linux, permission failures, stale candidates, restart/credential refresh, verified sandbox claims. (M2)
- [x] **G5 Compatibility:** concrete supported versions/toolchains, versioned sanitized fixtures, endpoint-to-test evidence, Go-client conformance checks, explicit expected skips. (M2)
- [x] **G6 Release gates:** required daemon lanes, exact-tag-commit evidence, verified repository rulesets, annotated tags, staged/smoke-tested release assets, failure-path rehearsal. (M2)
- [x] **G7 API and docs:** final naming/surface audit, removed `addProfile()`, compiler source-compatibility baseline, 100% authored DocC documentation, compiled examples and migration guide. (M3)
- [x] **G8 Consumers and maintenance:** NWX and second independent consumer, external technical review record, backup release owner, DCO/licensing, maintenance rehearsal automation. (M3)
- [x] **G9 Release candidate:** consumer evaluation and soak reports, no unresolved blocking defects, all required checks on the final release commit, complete distribution rehearsal.

Retain the unofficial-status disclaimer and explain the deferred stable-gap ledger in 1.0 release notes. Keep the public full-preferences replacement carrier internal unless lossless replacement semantics are established.

## Post-1.0

- **v1.1 Taildrop** — `file-put/<target>/<name>` (send), `files/` (inbox list, incl. `?waitfor=` long-poll), `file-targets`; progress observed via the `IncomingFiles`/`OutgoingFiles` notify fields modeled back in v0.4.0
- **v1.2 Taildrive** — `drive/fileserver-address`, `drive/shares` list/set/rename/delete
- **v1.3 Tailnet Lock** — the 13 `tka/*` endpoints under `TailnetLock` naming (note: `tka/modify` returns 204)
- **Stable-gap ledger** (additive, tracked in `endpoints.json` and CI-verified as upstream-stable):
  - `BugReportWithOpts` — a recording handle that keeps the POST body open until the caller ends the recording (upstream's contract); the experimental `record:` knob documents today's limitation
  - `DialTCP` / `UserDial` — raw duplex streams over HTTP upgrade; needs a Swift connection abstraction design spike first (issue draft 04)
- **Additional transport architectures** — additive after 1.0 where possible; the public transport contract and native safesocket discovery required by G2–G4 must settle before the freeze
- **Ongoing Experimental** — `debug` (`?action=` multiplexer), `pprof`, `update/install` + `update/progress` (`update/check` shipped supported in v0.11.0), `appc-route-info`, `policy/<scope>` (MDM/syspolicy), `debug-bus-graph|queues|events`, `prefs/service-clients`, and whatever upstream adds next; wrapped on demand, never SemVer-bound

---

## Cross-Cutting Tracks (remaining work)

The operational detail lives in [`Documentation/TESTING.md`](Documentation/TESTING.md) and [`Documentation/RELEASING.md`](Documentation/RELEASING.md). Most of what these tracks originally listed has shipped; what's left:

### Testing
- Retain the 85% coverage floor; use W1–W5's failure scenarios to drive meaningful new coverage
- Required before 1.0: framing/truncation, mutation/property, resource/cancellation, versioned-fixture, and streaming-soak evidence
- Extend the shipped Headscale login lifecycle with native discovery and restart recovery cases

### CI/CD
- Weekly upstream drift detection and Dependabot configuration already exist; retain and review them
- W6: supported-version PR/release gates, exact-SHA evidence, controlled skips, staged asset publication, and release rehearsal
- Evaluate additional static analysis where it covers real supported-language risks; do not use its presence as a substitute for transport/runtime evidence

### Documentation
- W7: complete authored API abstracts/topic curation, migration guide, and updated menu-bar/write/monitoring recipes
- Keep the AI-agent adapters (`.claude/skills/…`, `AGENTS.md`, `llms.txt`, copilot instructions) in sync with each release — INTEGRATING.md is the single source

### Distribution & Discoverability
- GitHub topics (maintainer-side): `tailscale`, `swift`, `swift-6`, `localapi`, `wireguard`, `vpn`, `macos`, `async-await`
- Tailscale Community Projects submission — maintainer-approval gated; unblocked now that SPI shows current releases
- Announcement wave: awesome-tailscale PR, r/Tailscale, Swift Forums; Show HN + Tailscale forum at 1.0
- homebrew-core as a post-1.0 aspiration once the notability bar is met
- Release mechanics: maintainer tag push on the tested release commit (single tag — >3 tags in one push suppresses GitHub push events), then the verified Homebrew tap bump
- Homebrew formula smoke test as part of release verification: `brew install` (or `brew audit` + install from the tap) against the freshly tagged release assets before announcing

---

## Non-Goals

- **Embedded Tailscale** — creating new tailnet nodes belongs in [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift)
- **CLI replacement** — `tailscale-swift` demonstrates the library; it does not compete with the official CLI
- **Shelling out** — everything in pure Swift
- **Wrapping everything** — `dial` (connection hijack with no clean Swift mapping — until the post-1.0 duplex abstraction exists), `conn25/state`, `alpha-set-device-attrs`, `check-so-mark-in-use`, `upload-client-metrics`, and `debug-capture` stay unsupported until a real use case appears; each has its reason recorded in the coverage matrix
- **Pre-1.0 API stability** — APIs may change before 1.0; from 1.0 the Stable tier follows SemVer strictly

## Contributing to the Roadmap

Need an endpoint sooner, or one that's tiered Unsupported? Open a GitHub issue with your use case, the endpoint, and the expected request/response shapes. Community input reorders this list.
