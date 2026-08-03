# Roadmap

This roadmap describes what remains between the current release and a complete, rigorously tested, well-documented 1.0 — and what "complete" means for a client of an API that Tailscale itself labels unstable. Shipped work lives in [`CHANGELOG.md`](CHANGELOG.md); this document tracks only what is yet to be done.

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

"Complete coverage" means **every LocalAPI endpoint has a documented status** — implemented, planned, experimental, or unsupported-with-reason — not that every endpoint has a wrapper. Connection-hijacking endpoints (`dial`), alpha endpoints, and Tailscale-internal plumbing stay unsupported until there is a real use case.

The policy is mechanically enforced today: `Documentation/endpoints.json` records two independent stability axes per endpoint (Tailscale's own "API maturity" annotation and this package's Swift-support promise) plus the upstream feature gate, all pinned to an immutable `tailscale/tailscale` commit and re-verified against that commit's source in CI (`Scripts/verify-upstream-maturity.py`); generated tables and a contradiction check keep the human docs honest.

## API Conventions

Standing policy for all code:

- **Public memberwise initializers on every model**, so consumers can construct fixtures for SwiftUI previews and their own tests.
- **Tolerant enums**: string/int enums from the wire use an `.unknown(raw)`/`.other` case rather than failing decodes when upstream adds values. Booleans upstream marks `omitempty` decode absent-as-false, never as optional.
- **`Sendable` everywhere, `Equatable` on models**; `Encodable` where round-tripping matters.
- **Typed errors** with actionable `recoverySuggestion`s; every request gets a configurable deadline. Typed status mapping, `Tailscale-Version` observation, and audit-reason injection apply to unary requests (streaming is documented as `.transport`-only).
- **Streaming resilience**: an undecodable line in a stream is skipped and surfaced through a reporting hook, never fatal to the stream. Reconnection with exponential backoff is an explicit opt-in.
- **Concurrency encoded in types**: `serve-config` reads return a snapshot carrying its ETag; writes require the snapshot, so a stale write surfaces as a typed conflict error rather than silent clobbering.
- **Naming follows Go `client/local`** adapted to Swift conventions — including upstream's `NetworkLock` → `TailnetLock` rename and `switchToEmptyProfile()` over the legacy `addProfile()`.
- **Secrets never reach diagnostic surfaces** — not logs, not `description`, not reflection; regression tests assert no substring of an injected secret escapes.

## Development Practice: Spike Before You Ship

No endpoint is implemented from documentation alone. Every new surface follows the same sequence:

1. **Spike against a real daemon.** Exercise the endpoint with `curl --unix-socket` (or a throwaway Swift scratch file) against an actual running tailscaled — locally and/or in the headscale integration environment — and observe real request/response shapes, headers, status codes, and streaming behavior.
2. **Cross-check upstream source at the pinned commit.** The authority is `tailscale/tailscale`: the handler in `ipn/localapi/`, the Go client method in `client/local/`, and the types in `tailcfg`/`ipn`. Public docs lag the code; the code decides field names, optionality, and edge behavior. Record the symbol, maturity, and gate in `endpoints.json` — CI verifies all three against the pinned revision.
3. **Capture fixtures from the spike.** Real (sanitized) responses become the versioned fixtures the unit tests decode — not hand-typed JSON guessed from docs.
4. **Then implement**, with the fixtures and the spike findings encoding the corner cases (empty bodies, 204s/201s, ETags, chunked framing) into tests before the API is considered done.

The spike workflow and fixture-capture script are documented in [`Documentation/TESTING.md`](Documentation/TESTING.md).

## Version Plan (remaining)

v0.4.0 through v0.11.0 have shipped; their contents are recorded in [`CHANGELOG.md`](CHANGELOG.md). What remains:

| Version | Theme | New endpoints | Key non-feature work |
|---------|-------|---------------|----------------------|
| **v0.12.0** | Always-on gap-fill & 1.0 runway | `shutdown`, `services` | Coverage floor 70 → 85; the menu-bar DocC tutorial; scripted headscale login-lifecycle test |
| **v1.0.0** | API freeze | — | Pre-freeze naming audit; drop deprecated `addProfile()`; 1.0 criteria below; SemVer commitment |
| **v1.1** | Taildrop | `file-put/`, `files/` (incl. long-poll), `file-targets` | Upload/download progress via IPN bus |
| **v1.2** | Taildrive | `drive/fileserver-address`, `drive/shares` CRUD | |
| **v1.3** | Tailnet Lock | 13 `tka/*` endpoints (`TailnetLock` naming) | |
| **Post-1.0 (additive)** | Stable-gap ledger | `BugReportWithOpts` recording handle; `DialTCP`/`UserDial` duplex abstraction | Both tracked in the coverage ledger; see below |
| **Ongoing** | Experimental debug surface | `debug` actions, `pprof`, `update/install|progress`, `appc-route-info`, `policy/*`, `debug-bus-*`, `prefs/service-clients` | Added on demand; never SemVer-bound |

## v0.12.0 — Always-On Gap-Fill & 1.0 Runway

**Goal:** wrap the last two always-registered handlers, get test coverage to the 1.0 bar, and finish the documentation set so v1.0.0 is purely a freeze-and-commit release.

### Library
- [ ] `shutdown()` — `POST /localapi/v0/shutdown` (destructive: terminates the daemon; wire-shape unit tests only, prominent warnings, never integration-tested against live daemons)
- [ ] `services()` — `GET /localapi/v0/services` (spike first: shape is Tailscale Services / VIP services state)

### Testing
- [ ] Coverage floor ratchets 70 → 85 (fill the gaps the report shows; streaming path and transport parsers stay fully unit-tested)
- [ ] Scripted login lifecycle against headscale (interactive login is scriptable there) — the one open item carried from v0.9.0
- [ ] Decide and document the upstream re-pin cadence (issue draft 07): a scheduled job that re-derives maturity/gates against a newer upstream commit and opens a PR when anything drifts

### Docs
- [ ] DocC tutorial: *Build a Tailscale menu bar app*
- [ ] Verify docs CI hard-fails on undocumented public symbols (the 1.0 criterion) and fix any stragglers

## v1.0.0 — API Freeze

**Criteria (checklist, not a feature list):**

- [ ] Every always-on LocalAPI handler is wrapped or explicitly tiered Experimental/Unsupported in [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md) — after v0.12.0 this means zero unwrapped always-on handlers
- [ ] Test coverage ≥ 85%; streaming path and transport parsers fully unit-tested
- [x] Integration matrix green against at least two tailscaled versions (three hermetic headscale lanes — stable / previous-stable / unstable — plus a live self-hosted macOS lane, on every PR)
- [ ] Complete DocC Topics tree (docs CI fails on undocumented public symbols), one tutorial, at least two buildable examples in `Examples/` (StatusDemo and Recipes exist; tutorial ships in v0.12.0)
- [x] Homebrew formula, Swift Package Index docs, and release automation all live
- [ ] Unofficial-status disclaimer and the stability policy present in README, DocC landing page, and error output (README/DocC done; audit error/CLI output)
- [ ] **Pre-freeze API audit**: naming pass against `client/local` conventions; remove deprecated `addProfile()`; decide whether the transport-neutral core and safesocket parity work (issue drafts 05/06) changes any public API — if it does, it lands before the freeze or is redesigned to be additive
- [ ] Declare the stable-gap ledger items (`BugReportWithOpts`, `DialTCP`/`UserDial`) explicitly post-1.0 in the release notes
- [ ] Governance decisions recorded (issue draft 08): contribution policy/DCO, naming/disclaimer posture for the announcement
- [ ] From here: strict SemVer for Stable tier; Experimental tier explicitly exempt

## Post-1.0

- **v1.1 Taildrop** — `file-put/<target>/<name>` (send), `files/` (inbox list, incl. `?waitfor=` long-poll), `file-targets`; progress observed via the `IncomingFiles`/`OutgoingFiles` notify fields modeled back in v0.4.0
- **v1.2 Taildrive** — `drive/fileserver-address`, `drive/shares` list/set/rename/delete
- **v1.3 Tailnet Lock** — the 13 `tka/*` endpoints under `TailnetLock` naming (note: `tka/modify` returns 204)
- **Stable-gap ledger** (additive, tracked in `endpoints.json` and CI-verified as upstream-stable):
  - `BugReportWithOpts` — a recording handle that keeps the POST body open until the caller ends the recording (upstream's contract); the experimental `record:` knob documents today's limitation
  - `DialTCP` / `UserDial` — raw duplex streams over HTTP upgrade; needs a Swift connection abstraction design spike first (issue draft 04)
- **Transport-neutral core & safesocket parity** (issue drafts 05/06) — architecture tracks; timing depends on the pre-freeze audit above
- **Ongoing Experimental** — `debug` (`?action=` multiplexer), `pprof`, `update/install` + `update/progress` (`update/check` shipped supported in v0.11.0), `appc-route-info`, `policy/<scope>` (MDM/syspolicy), `debug-bus-graph|queues|events`, `prefs/service-clients`, and whatever upstream adds next; wrapped on demand, never SemVer-bound

---

## Cross-Cutting Tracks (remaining work)

The operational detail lives in [`Documentation/TESTING.md`](Documentation/TESTING.md) and [`Documentation/RELEASING.md`](Documentation/RELEASING.md). Most of what these tracks originally listed has shipped; what's left:

### Testing
- Coverage gate 70 now → 85 at v0.12.0/1.0
- Mutation/property tests: randomized truncation and field-deletion of fixtures must throw typed errors, never crash (nice-to-have before 1.0)
- Scripted headscale login lifecycle (v0.12.0)

### CI/CD
- Upstream drift automation: scheduled re-pin job for `endpoints.json` provenance (decide cadence in v0.12.0)
- CodeQL analysis; Dependabot for github-actions and swift ecosystems (not yet enabled)

### Documentation
- The menu-bar tutorial (v0.12.0); everything else in the article set has shipped
- Keep the AI-agent adapters (`.claude/skills/…`, `AGENTS.md`, `llms.txt`, copilot instructions) in sync with each release — INTEGRATING.md is the single source

### Distribution & Discoverability
- GitHub topics (maintainer-side): `tailscale`, `swift`, `swift-6`, `localapi`, `wireguard`, `vpn`, `macos`, `async-await`
- Tailscale Community Projects submission — maintainer-approval gated; unblocked now that SPI shows current releases
- Announcement wave: awesome-tailscale PR, r/Tailscale, Swift Forums; Show HN + Tailscale forum at 1.0
- homebrew-core as a post-1.0 aspiration once the notability bar is met
- v0.11.0 release mechanics: maintainer tag push after the release PR merges (single tag — >3 tags in one push suppresses GitHub push events), then the Homebrew tap bump

---

## Non-Goals

- **Embedded Tailscale** — creating new tailnet nodes belongs in [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift)
- **CLI replacement** — `tailscale-swift` demonstrates the library; it does not compete with the official CLI
- **Shelling out** — everything in pure Swift
- **Wrapping everything** — `dial` (connection hijack with no clean Swift mapping — until the post-1.0 duplex abstraction exists), `conn25/state`, `alpha-set-device-attrs`, `check-so-mark-in-use`, `upload-client-metrics`, and `debug-capture` stay unsupported until a real use case appears; each has its reason recorded in the coverage matrix
- **Pre-1.0 API stability** — APIs may change before 1.0; from 1.0 the Stable tier follows SemVer strictly

## Contributing to the Roadmap

Need an endpoint sooner, or one that's tiered Unsupported? Open a GitHub issue with your use case, the endpoint, and the expected request/response shapes. Community input reorders this list.
