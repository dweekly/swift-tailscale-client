# Roadmap

This roadmap describes how `swift-tailscale-client` gets from v0.3.1 to a complete, rigorously tested, well-documented 1.0 — and what "complete" means for a client of an API that Tailscale itself labels unstable.

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

Three mechanisms make this policy operational:

1. **Capability probing.** `POST /localapi/v0/debug-optional-features` reports which optional features a daemon was compiled with. v0.4.0 exposes this as `client.daemonFeatures()` and maps 404s on optional endpoints to a typed `.endpointUnavailable` error instead of a generic status failure.
2. **Version attestation.** Every release states "tested against Tailscale X.Y" in its release notes, and the integration suite runs against a matrix of tailscaled versions (current stable, previous stable, unstable).
3. **Tolerant decoding.** Models never fail on unknown enum values or new fields; upstream additions degrade gracefully (see API Conventions).

## API Conventions

These conventions apply to all new code and are retrofitted to existing types in v0.4.0:

- **Public memberwise initializers on every model**, so consumers can construct fixtures for SwiftUI previews and their own tests.
- **Tolerant enums**: string/int enums from the wire use an `.unknown(raw)` case (as `BackendState` already does) rather than failing decodes when upstream adds values.
- **`Sendable` everywhere, `Equatable` on models**; `Encodable` where round-tripping matters (`Prefs`, `MaskedPrefs`, serve config).
- **Typed identifiers** (`StableNodeID`, node keys) as lightweight wrapper structs instead of bare `String`.
- **Typed errors**: `TailscaleClientError` grows `.endpointUnavailable(endpoint:hint:)` and `.timeout`; every request gets a configurable deadline.
- **Streaming resilience**: an undecodable line in a stream is skipped and surfaced through a reporting hook, never fatal to the stream. Reconnection with exponential backoff is available as an explicit opt-in.
- **Concurrency encoded in types**: `serve-config` reads return a snapshot carrying its ETag; writes require the snapshot, so a stale write surfaces as a typed conflict error rather than silent clobbering (mirroring upstream's `If-Match` requirement).
- **Naming follows Go `client/local`** adapted to Swift conventions — including upstream's `NetworkLock` → `TailnetLock` rename.

## Development Practice: Spike Before You Ship

No endpoint is implemented from documentation alone. Every new surface follows the same sequence:

1. **Spike against a real daemon.** Exercise the endpoint with `curl --unix-socket` (or a throwaway Swift scratch file) against an actual running tailscaled — locally and/or in the headscale integration environment — and observe real request/response shapes, headers, status codes, and streaming behavior.
2. **Cross-check upstream source.** The authority is `tailscale/tailscale`: the handler in `ipn/localapi/`, the Go client method in `client/local/`, and the types in `tailcfg`/`ipn`. Public docs lag the code; the code decides field names, optionality, and edge behavior.
3. **Capture fixtures from the spike.** Real (sanitized) responses become the versioned fixtures the unit tests decode — not hand-typed JSON guessed from docs.
4. **Then implement**, with the fixtures and the spike findings encoding the corner cases (empty bodies, 204s, ETags, chunked framing) into tests before the API is considered done.

The spike workflow and fixture-capture script are documented in [`Documentation/TESTING.md`](Documentation/TESTING.md).

## Version Plan

| Version | Theme | New endpoints | Key non-feature work |
|---------|-------|---------------|----------------------|
| **v0.4.0** | Reliability foundations | `debug-optional-features` | Shipped mocks library; streaming hardening; complete `IPNNotify`; public model inits; timeouts; CI matrix + coverage |
| **v0.5.0** | Linux & hermetic integration CI | — | POSIX socket transport; testable HTTP/chunked parsers; headscale-based integration tests in CI |
| **v0.6.0** | Network diagnostics | `derpmap`, `suggest-exit-node`, `usermetrics` + native STUN netcheck | CLI becomes a product; Homebrew tap; `--json` everywhere |
| **v0.7.0** | DNS & routing diagnostics | `dns-osconfig`, `dns-query`, `check-ip-forwarding`, `routecheck`, `peer-by-id`, `user-profile`; *Experimental:* `bugreport`, `logtap`, `goroutines` | `experimental` namespace debuts |
| **v0.8.0** | Configuration (first write APIs) | `prefs` PATCH, `check-prefs`, `set-use-exit-node-enabled`, `set-expiry-sooner`, `reload-config`, `start` | Typed `MaskedPrefs` builder; write-safety docs |
| **v0.9.0** | Auth, profiles, GUI contract | `login-interactive`, `logout`, `reset-auth`, `profiles/*`, `id-token`; *Experimental:* `set-gui-visible`, `set-push-device-token`, `handle-push-message` | Login flow guide (BrowseToURL via IPN bus) |
| **v0.10.0** | Serve, Funnel & certificates | `serve-config`, `cert-domains`, `cert/<domain>`, `query-feature`, `set-dns` | ETag-typed optimistic concurrency |
| **v1.0.0** | API freeze | gap-fill: `shutdown`, `services` | 1.0 criteria below; SemVer commitment |
| **v1.1** | Taildrop | `file-put/`, `files/` (incl. long-poll), `file-targets` | Upload/download progress via IPN bus |
| **v1.2** | Taildrive | `drive/fileserver-address`, `drive/shares` CRUD | |
| **v1.3** | Tailnet Lock | 13 `tka/*` endpoints (`TailnetLock` naming) | |
| **Ongoing** | Experimental debug surface | `debug` actions, `pprof`, `update/*`, `appc-route-info`, `policy/*`, `debug-bus-*`, `prefs/service-clients` | Added on demand; never SemVer-bound |

Every version below carries the same four subsections — **Library**, **CLI**, **Testing**, **Docs** — so "done" is auditable per release.

---

## v0.4.0 — Reliability Foundations

**Goal:** make everything already shipped trustworthy before adding surface area. Almost no new endpoints; every release after this one builds on this infrastructure.

### Library
- [ ] `daemonFeatures()` — wrap `POST /localapi/v0/debug-optional-features`; new `OptionalFeatures` model
- [ ] `.endpointUnavailable` and `.timeout` cases on `TailscaleClientError`; per-request deadline in `TailscaleClientConfiguration`
- [ ] Streaming hardening in `watchIPNBus()`:
  - Skip-and-report policy for undecodable lines (today a single bad line kills the stream)
  - Opt-in auto-reconnect with exponential backoff, re-requesting initial state
  - Remove the stray `#if DEBUG` print from the hot path
- [ ] Complete `IPNNotify`: add `Prefs`, `NetMap`, `IncomingFiles`, `OutgoingFiles`, `FilesWaiting` fields (models may be minimal, but the watch options that request them must have decodable payloads)
- [ ] Public memberwise inits + `Equatable` on all models; adopt tolerant-enum convention package-wide
- [ ] Always send `Host: local-tailscaled.sock` (upstream `validHost` precondition)
- [ ] Stop hardcoding `capabilityVersion: 1`; document what the value means and how to override it
- [ ] Round out `StatusQuery` beyond `peers`; make `LocalAPIDiscovery` public so apps can report *how* the daemon was found
- [ ] New **`TailscaleClientMocks` library product**: `MockTransport` with scripted responses *and* scripted streams (per-line delays, injected errors, EOF), `RequestRecorder`, fixture loaders. Ships to consumers so they can test their own apps; replaces the three private copies in our test suite.

### CLI
- [ ] `tailscale-swift features` — display daemon optional features

### Testing
- [ ] First real streaming unit tests: scripted line sequences, malformed line mid-stream, transport error mid-stream, cancellation, reconnect behavior
- [ ] Migrate all tests to the shared mocks product
- [ ] Coverage measurement in CI with an initial 75% gate (ratchets to 85% by 1.0)
- [x] Real-daemon integration suite in CI via the self-hosted macOS runner (`integration.yml`: fork-guarded, read-only tests against the runner's live tailscaled)

### Docs
- [ ] `.swift-format` checked in; CI matrix (macOS + Linux build, iOS/tvOS/watchOS build-only checks)
- [ ] DocC Topics tree updated to include all IPN bus symbols (currently absent)

## v0.5.0 — Linux & Hermetic Integration CI

**Goal:** Linux support is a feature-enabler, not a courtesy. The self-hosted macOS runner already provides real-daemon integration CI against one live Tailscale install; headscale on Linux runners adds what it can't — a hermetic environment safe for write-API mutation tests and a matrix across tailscaled versions.

### Library
- [x] Unix socket transport runs on raw POSIX sockets shared across Darwin and Linux, with poll-based reads so cancellation works against a silent daemon. No new dependencies — staying zero-dependency is a selling point; swift-nio is not worth the tree for one socket.
- [x] HTTP response parsing and chunked-transfer decoding extracted into internal pure types (`HTTPWireFormat`, `HTTPHeadBuffer`, `NewlineFramer`, `ChunkedTransferDecoder`) that are unit-testable without a socket

### CLI
- [x] CLI builds and runs on Linux (unix socket endpoints; loopback streaming stays Darwin-only)

### Testing
- [x] Parser corner-case suite: chunk-size lines split across reads, trailers, chunk extensions, oversized (>1 MB) payloads, UTF-8 sequences split across read boundaries, oversized heads
- [x] `integration-linux.yml`: nightly + on-demand hermetic workflow — headscale control plane + real tailscaled (`--tun=userspace-networking`), pre-auth key minted locally, no secrets
- [x] Matrix over tailscaled versions in the headscale workflow: stable, previous-stable (pinned 1.96.5), unstable

### Docs
- [ ] [`Documentation/TESTING.md`](Documentation/TESTING.md) is the reference for the harness and fixture process

## v0.6.0 — Network Diagnostics

**Goal:** the NWX feature wave: DERP visibility, exit node optimization, and a native netcheck.

### Library
- [x] `derpMap()` — `GET /localapi/v0/derpmap`; `DERPMap`/`DERPRegion`/`DERPNode` models
- [x] `suggestExitNode()` / `suggestExitNode(forceProbe: true)` — GET + POST variants
- [x] `userMetrics()` — `GET /localapi/v0/usermetrics`
- [x] **Native STUN netcheck** (pure Swift; there is no LocalAPI netcheck endpoint — the official CLI does client-side STUN): enumerate STUN endpoints from the DERP map, measure per-region latency, detect NAT type from mapped-address variation, report UDP/IPv4/IPv6 capability
- [x] Response models are fully `Codable` (encode side added for `--json`, caching, snapshots)

### CLI
- [x] `derpmap`, `netcheck`, `suggest-exit` (+ `usermetrics`) subcommands
- [x] CLI promoted to an **executable product** in `Package.swift`
- [x] `--json` output on every subcommand with a structured result (`metrics`/`usermetrics` stay Prometheus text, already machine-readable); man pages available via ArgumentParser's `generate-manual` plugin (see `Documentation/HOMEBREW.md`)
- [ ] Homebrew tap `dweekly/homebrew-tap` with a `tailscale-swift` formula built from the release tag — formula template ready in [`Documentation/HOMEBREW.md`](Documentation/HOMEBREW.md); tap repo + sha256 happen at release time

### Testing
- [x] STUN unit tests against recorded binding responses; live netcheck integration test (skips where CI blocks UDP)

### Docs
- [ ] Announcement wave: awesome-tailscale PR, r/Tailscale, Swift Forums (this is the first demo-able `brew install` moment)

## v0.7.0 — DNS & Routing Diagnostics; Experimental Debut

### Library
- [x] `dnsOSConfig()`, `dnsQuery(name:type:)` — DNS diagnostics
- [x] `checkIPForwarding()` — subnet-router preflight (upstream has no standalone `routecheck` endpoint; route probing is the `?probe=true` hook behind `suggest-exit-node`, wrapped since v0.6.0)
- [x] `peer(byID:)`, `userProfile(byID:)` — detail lookups
- [x] `client.experimental` namespace lands, opening with `bugreport()`, `goroutines()`, and streaming `logtap()` (the second streaming consumer — proves the v0.4 stream machinery generalizes)

### CLI
- [x] `dns status`, `dns query <name>`, `check-forwarding`

### Testing
- [x] `logtap` streaming tests reuse the scripted-stream harness; DNS fixtures for wire-format responses

### Docs
- [x] DocC article: *Experimental APIs & Stability Tiers* — landed alongside the full article set (Getting Started, Discovery & Permissions, Streaming, Error Handling, Version Compatibility), pulling the 1.0 documentation criteria forward

## v0.8.0 — Configuration (First Write APIs)

### Library
- [x] `editPrefs(_:)` — `PATCH /localapi/v0/prefs` with a typed `MaskedPrefs` builder (only fields you set are sent, mirroring upstream's mask semantics)
- [x] `checkPrefs(_:)` — validate without applying
- [x] `setUseExitNode(enabled:)`, `setExpirySooner(_:)`, `reloadConfig()`, `start(options:)` (minimal `StartOptions`; full `ipn.Options` on demand)
- [x] First real use of `TailscaleRequest.body` plumbing

### CLI
- [x] `set exit-node <node>`, `set shields-up`, `set accept-routes`

### Testing
- [x] Mutation tests in the integration suite: apply → verify → revert — double-gated behind `TAILSCALE_INTEGRATION_WRITE=1`, set only in the hermetic headscale workflow
- [x] Unit tests assert exact PATCH bodies (mask correctness is the whole game)

### Docs
- [x] DocC article: *Writing Safely* (check-prefs first, mask semantics, how to avoid clobbering user config)

## v0.9.0 — Auth, Profiles & the GUI Contract

### Library
- [x] `loginInteractive()`, `logout()`, `resetAuth()` — paired with `watchIPNBus` for the `BrowseToURL` flow
- [x] `profiles()` / `currentProfile()` / `addProfile()` / `switchProfile(_:)` / `deleteProfile(_:)` — multi-account
- [x] `idToken(audience:)`
- [x] *Experimental:* `setGUIVisible(_:sessionID:)`, `setPushDeviceToken(_:)`, `handlePushMessage(_:)` — the endpoints Tailscale's own GUI clients use; relevant to any serious macOS/iOS app embedding this package

### CLI
- [x] `login`, `logout` (guarded by --yes), `switch <profile>` (lists when bare)

### Testing
- [ ] Full login lifecycle against headscale (interactive login is scriptable there) — read-only profiles checks run live everywhere; the scripted login remains open

### Docs
- [x] DocC article: *The Login Flow* (BrowseToURL + IPN bus state machine, headless bring-up, profile lifecycle)

## v0.10.0 — Serve, Funnel & Certificates

### Library
- [ ] `serveConfig()` → `ServeConfigSnapshot` (payload + ETag); `setServeConfig(_ snapshot:)` sends `If-Match` — stale writes become a typed conflict error
- [ ] `certDomains()`, `certificate(domain:type:minValidity:)` — ACME cert material (pair/cert/key)
- [ ] `queryFeature(_:)`, `setDNS(name:value:)` (ACME DNS-01)

### CLI
- [ ] `serve status`, `cert <domain>`

### Testing
- [ ] Concurrency test: two clients racing serve-config writes; loser must get the typed conflict, never silent clobber

### Docs
- [ ] DocC article: *Serve, Funnel & Certificates*

## v1.0.0 — API Freeze

**Criteria (checklist, not a feature list):**

- [ ] Every always-on LocalAPI handler is wrapped or explicitly tiered Experimental/Unsupported in [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md)
- [ ] Test coverage ≥ 85%; streaming path and transport parsers fully unit-tested
- [ ] Integration matrix green against at least two tailscaled versions (current + previous stable)
- [ ] Complete DocC Topics tree (docs CI fails on undocumented public symbols), one tutorial, at least two buildable examples in `Examples/`
- [ ] Homebrew formula, Swift Package Index docs, and release automation all live
- [ ] Unofficial-status disclaimer and the stability policy present in README, DocC landing page, and error output
- [ ] From here: strict SemVer for Stable tier; Experimental tier explicitly exempt

## Post-1.0

- **v1.1 Taildrop** — `file-put/<target>/<name>` (send), `files/` (inbox list, incl. `?waitfor=` long-poll), `file-targets`; progress observed via the `IncomingFiles`/`OutgoingFiles` notify fields modeled back in v0.4.0
- **v1.2 Taildrive** — `drive/fileserver-address`, `drive/shares` list/set/rename/delete
- **v1.3 Tailnet Lock** — the 13 `tka/*` endpoints under `TailnetLock` naming (note: `tka/modify` returns 204)
- **Ongoing Experimental** — `debug` (`?action=` multiplexer), `pprof`, `update/check|install|progress`, `appc-route-info`, `policy/<scope>` (MDM/syspolicy), `debug-bus-graph|queues|events`, `prefs/service-clients`, and whatever upstream adds next; wrapped on demand, never SemVer-bound

---

## Cross-Cutting Tracks

Summaries here; the operational detail lives in [`Documentation/TESTING.md`](Documentation/TESTING.md) and [`Documentation/RELEASING.md`](Documentation/RELEASING.md).

### Testing
- Shipped `TailscaleClientMocks` product (scripted responses and streams) — both our harness and an adoption feature
- Fixture library organized `Fixtures/v<tailscale-version>/<endpoint>.json`, captured from real daemons by a documented script
- Mutation/property tests: randomized truncation and field-deletion of fixtures must throw typed errors, never crash
- Coverage gate 75% now, 85% at 1.0
- Hermetic integration in CI via headscale on Linux runners, matrixed over tailscaled versions

### CI/CD
- `ci.yml`: build+test matrix (macos-26, ubuntu-24.04); swift-format lint against the checked-in `.swift-format`; `xcodebuild` build-only checks for iOS/tvOS/watchOS (declared in `Package.swift`, so they must at least compile); coverage upload
- `docs.yml`: DocC build failing on documentation warnings; GitHub Pages hosts the bleeding-edge snapshot; **Swift Package Index hosts canonical per-release docs** via `.spi.yml`
- `integration.yml`: nightly headscale matrix (see Testing)
- `release.yml` on tag `v*`: verify tag ↔ CHANGELOG entry, run tests, create the GitHub Release with notes extracted from CHANGELOG, attach CLI binaries (macOS universal, Linux x86_64/arm64), open the Homebrew tap bump PR
- CodeQL analysis; Dependabot for github-actions and swift ecosystems

### Documentation
- DocC articles: Getting Started · Discovery & Permissions (TCC tradeoffs) · Streaming Guide · Error Handling · Writing Safely · Experimental APIs & Stability Tiers · Version Compatibility
- One DocC tutorial: *Build a Tailscale menu bar app*
- `Examples/MenuBarStatus` and `Examples/Dashboard`: standalone SPM packages with path dependencies, built by CI, designed to be copy-pasted out
- README "Choosing the right tool" section: an honest options map (this package vs TailscaleKit/tsnet embedding vs shelling out to the official CLI vs the api.tailscale.com admin API) so developers land on the right project fast — kept current as the landscape changes
- **AI-agent skill**: the repo ships `.claude/skills/swift-tailscale-client/SKILL.md`, a machine-readable guide for coding agents covering what the package offers, when (not) to use it, how to add the SPM dependency, quickstart patterns, and testing with the mocks product — updated alongside each release

### Distribution & Discoverability
- `.spi.yml` (platforms + documentation targets) — done
- GitHub topics: `tailscale`, `swift`, `swift-6`, `localapi`, `wireguard`, `vpn`, `macos`, `async-await`
- Homebrew: tap first (v0.6.0), homebrew-core only as a post-1.0 aspiration once the notability bar is met
- Release hygiene: retro-create the missing annotated `v0.3.0` tag; standardize on annotated tags; backfill GitHub Releases for v0.1.0–v0.3.1 from CHANGELOG
- Staged announcements: awesome-tailscale + r/Tailscale + Swift Forums at v0.6.0; Show HN + Tailscale forum at 1.0

---

## Non-Goals

- **Embedded Tailscale** — creating new tailnet nodes belongs in [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift)
- **CLI replacement** — `tailscale-swift` demonstrates the library; it does not compete with the official CLI
- **Shelling out** — everything in pure Swift
- **Wrapping everything** — `dial` (connection hijack with no clean Swift mapping), `conn25/state`, `alpha-set-device-attrs`, `disconnect-control`, `check-so-mark-in-use`, `upload-client-metrics`, and `debug-capture` stay unsupported until a real use case appears; each has its reason recorded in the coverage matrix
- **Pre-1.0 API stability** — APIs may change before 1.0; from 1.0 the Stable tier follows SemVer strictly

## Contributing to the Roadmap

Need an endpoint sooner, or one that's tiered Unsupported? Open a GitHub issue with your use case, the endpoint, and the expected request/response shapes. Community input reorders this list.
