# Changelog

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`services()`** wraps `GET /localapi/v0/services` — Tailscale Services (VIP services) visible to this node, keyed by `svc:` name, with `ServiceDetails`/`ServiceAction` models (addresses, `ProtoPortRange` text-form ports, open-set action slugs with JSON attribute maps; upstream `GetServices`, unannotated). Daemons without a netmap answer 503; daemons predating the endpoint surface `.endpointUnavailable`. CLI: `tailscale-swift services` (with `--json`).
- **`shutdownTailscaled()`** wraps `POST /localapi/v0/shutdown` (upstream `ShutdownTailscaled`, annotated unstable) — graceful daemon exit. Destructive and documented as such; requires write access **and** the `AllowTailscaledRestart` policy (403 → `.permissionDenied`); wire-shape unit tests only, never exercised against live daemons.
- **Linux interface discovery**: `NetworkInterfaceDiscovery` (and therefore `StatusResponse.interfaceName`/`interfaceInfo`) now works on Glibc platforms — the `getifaddrs` path was Darwin-gated, silently returning nil on Linux. The whole discovery test suite now runs on Linux CI as the regression assertion.
- **Model-conformance gate**: `Scripts/check-model-conformance.py` enforces the API conventions mechanically in CI — every Codable struct must be Sendable + Equatable with a public init, and every raw-value wire enum must decode tolerantly. Its first run caught a real bug (see Fixed). "Tolerant" is proven, not assumed: a custom `init(from:)` only passes if it demonstrably falls back (`?? .other` / `self = .other`), so a future *strict* custom decoder fails the gate instead of sneaking past it (negative-tested), and the two decoded wire enums carry executable unknown-value decode tests.
- **Full upstream handler inventory**: `endpoints.json` now records the 20 registered-but-unwrapped LocalAPI handlers (debug surface, `dial`, `pprof`, …) with their gates and reasons, and `verify-upstream-maturity.py` fails when any handler derivable from the pinned sources is missing from both lists, when an inventory entry goes stale, or when an unwrapped handler's gate drifts. This closes the drift-automation blind spot where a **new** upstream endpoint derived cleanly, was compared against nothing, and the weekly run reported clean (negative-tested for all three failure modes).
- **Upstream drift automation** (issue draft 07): a weekly `upstream-drift` workflow re-derives maturity/gates/capability against *current* tailscale/tailscale main (`verify-upstream-maturity.py --against-revision`) and files/updates a re-pin issue describing exactly what moved. The pinned verification in regular CI is unchanged.
- **Strict DocC lane**: PRs now build documentation with `--warnings-as-errors` (broken symbol links and malformed directives fail before deploy time), and the documentation-coverage table gates as regression floors (Types 90% / Members 68% / Globals 1% abstract coverage; measured 93/70/1.6) — the pre-1.0 audit raises them to 100%.
- **DocC tutorial**: *Build a Tailscale menu bar app* — a step-by-step tutorial (observable model seeded from `status()`, live updates via `watchIPNBus` with reconnect, `MenuBarExtra` assembly) whose code mirrors the compiled `Examples/Recipes` menu-bar recipe.
- **Coverage floor ratcheted 70 → 85** (85.9% measured): the CI gate now surfaces the measured percentage plus the ten worst-covered files as check-run annotations, and that report drove the closing test batches — an edge-coverage suite (every error case's description/recovery/preview text, reconnect backoff growth, redaction edge shapes) and full-field encode/decode round-trips for the least-covered model files.
- **`startFreshProfile(controlURL:authKey:)`** — the LocalAPI equivalent of `tailscale up --login-server`, and the missing piece of the auth lifecycle: `logout()` deletes the profile (control URL included), so a subsequent `loginInteractive()` dialed the *default* control plane — observed live in the hermetic lane, where headscale could never approve a `login.tailscale.com` URL. Seeds upstream's `ipn.NewPrefs()` defaults (verified at the pinned revision, field for field — `Prefs` gained `noStatefulFiltering` so the `NewPrefs` value actually reaches the wire instead of silently degrading subnet-router behavior) plus the control URL over `start`'s `UpdatePrefs`, and rejects empty or non-HTTP(S) control URLs with `.transport(.invalidURL)` — upstream reads an empty control URL as "the default Tailscale control plane", which an explicit call to this method never means. The raw `UpdatePrefs` carrier is deliberately **internal**: this package's `Prefs` models a subset of `ipn.Prefs`, so re-encoding a fetched snapshot would silently zero unmodeled fields (services advertisement, stateful filtering, remote config, drive shares, …) — it stays scoped to the fresh-profile helper until `Prefs` is lossless (tracked for the pre-1.0 audit).
- **Scripted login-lifecycle test** (the one open item carried from v0.9.0): the hermetic headscale lane now drives the interactive auth flow end to end — `logout()` → `startFreshProfile(controlURL:)` → `loginInteractive()` → `BrowseToURL` from the IPN bus (asserted to point at the seeded control server) → approval via the headscale CLI → Running. Triple-gated (`TAILSCALE_INTEGRATION_LOGIN=1` on top of the integration/write gates) and run as a separate final step so the main suite always sees a logged-in daemon.

### Fixed

- `IPNState` (IPN bus backend state) decodes unknown values as a new `.other` case instead of failing the notification line — upstream adding a state no longer costs you the notify. Caught by the new model-conformance gate.

## [0.11.0] - 2026-08-03

### Security

- **No authentication-token material is logged anymore** (upstream-readiness issue 01): discovery debug logging previously printed the first eight characters of the macOS sameuserproof token, and several log lines included proof-file *paths whose filename embeds the full token*. All discovery logging now flows through a capturable sink with proof-path redaction, and regression tests inject a recognizable secret and assert no diagnostic surface emits any ≥4-character substring of it. `TailscaleClientConfiguration`, `LocalAPIDiscovery.Result`, and `CertPair` gained redacting `description`s **and redacting `customMirror`s**, so neither printing nor reflection (`dump(_:)`, `Mirror`, debugger/playground rendering — including nested inside reflected containers) can leak `authToken`/private-key material. Integrators: treat `authToken`, `idToken(audience:)` responses, `CertPair.privateKeyPEM`, and audit reasons as secrets in your own logs.

### Added

- **Upstream request/version/error contract** (upstream-readiness issue 03):
  - The default `Tailscale-Cap` is now **144**, pinned to a verified upstream revision with documented provenance and an update procedure (`TailscaleClientConfiguration.defaultCapabilityVersion`); `TAILSCALE_LOCALAPI_CAPABILITY` and explicit configuration still override. `Scripts/check-release-consistency.sh` fails CI when any doc states a different default; `Scripts/verify-upstream-maturity.py` verifies the constant against the pinned upstream revision.
  - The client observes the daemon's `Tailscale-Version` response header; `versionDiagnostics()` reports package version, advertised capability, and daemon version — mismatches are diagnostic, never request failures.
  - New typed errors: `.permissionDenied(body:endpoint:)` (HTTP 403), `.rateLimited(retryAfterSeconds:body:endpoint:)` (HTTP 429; `Retry-After` parsed per RFC 9110 — digit-only delta-seconds or any of the three HTTP-date forms recipients must accept, with malformed/signed/fractional/non-finite values yielding `nil` instead of nonsense), and `.peerNotFound(endpoint:)` (`whois` 404, upstream `ErrPeerNotFound`).
  - `TailscaleClient.withAuditReason("ticket…") { … }` scopes a justification to the operations inside — sent via the upstream `X-Tailscale-Reason` header (Base64), the mechanism always-on-mode policies use to permit audited operations. The value is task-local (mirroring upstream's per-request context scoping), so concurrent operations can never contaminate each other's reasons.
  - Documented contract boundary: typed status mapping, version observation, and audit-reason injection apply to **unary** requests; streaming connections (`watchIPNBus`, `logtap`) surface failures as `.transport`.
- **Dual-axis endpoint stability** (upstream-readiness issue 02): `Documentation/endpoints.json` now records Tailscale's own per-method "API maturity" (`upstream_maturity`: stable/unstable/unspecified, with `upstream_symbol_maturity` per-symbol exceptions where one endpoint aggregates methods of differing maturity) independently from this package's `swift_support` promise, plus the corresponding Go `upstream_symbol` and an `upstream_stable_unimplemented` ledger (WhoIs variants, CheckUpdate, DisconnectControl, DialTCP/UserDial). Provenance is pinned to an **immutable upstream commit SHA**, and the new `Scripts/verify-upstream-maturity.py` re-derives every annotation from the pinned sources in CI — the check that caught `CheckUDPGROForwarding` (upstream-unstable, wrongly seeded as a stable gap) and `SwitchToEmptyProfile` (already implemented: `addProfile()` performs the same `PUT /profiles/`). Each endpoint's `gate` now states the actual upstream registration condition (verified against `ipn/localapi/localapi.go` at the pinned commit by the same script — which caught seventeen wrong gate values, e.g. `usermetrics` needs `HasUserMetrics`, `watch-ipn-bus` needs `HasIPNBus`, `goroutines` is core, `logtap` needs `HasLogTail`). The generated coverage and quick-reference tables render both axes. `disconnect-control` reclassified from "test-harness tool" to upstream-stable administrative operation.
- **Stable-parity gap-fill** (upstream-readiness issue 04, all but the DialTCP/UserDial design spike and a faithful BugReportWithOpts recording handle): typed whois variants — `whois(address:protocol:)`, `whois(nodeKey:)`, `whois(address:scopedToDestination:)`, `whois(address:forService:)` — sharing the typed `.peerNotFound` on 404; `checkUpdate()` over `update/check` (reports only, installs nothing; `ClientVersionStatus` enriched with latest-version/urgency/notify fields, and its `omitempty` booleans decode absent-as-false to match the real wire); `disconnectControl()` with explicit administrative documentation (HA replica drain — never exercised against live daemons in tests); `checkUDPGROForwarding()` (upstream annotates this one *unstable* — shipped as supported normalization, not a stable-parity item); and a supported `bugReport(note:)` facade wrapping upstream `BugReport` (the diagnose/record knobs stay in `experimental`; `BugReportWithOpts` stays in the ledger because its recording contract holds the request body open, which this client cannot do yet — the `record:` knob now documents that its window closes immediately). `switchToEmptyProfile()` adopts the upstream name for the existing `PUT /profiles/` operation with the daemon's `201 Created` contract pinned by test. The optional-endpoint gates mirror upstream registration: `update/check` needs `HasClientUpdate`, `disconnect-control` needs `HasDebug || HasAdvertiseRoutes`, and `check-udp-gro-forwarding`/`check-ip-forwarding` need `HasAdvertiseRoutes` — feature-minimal daemons throw `.endpointUnavailable`, not a generic 404. The `upstream_stable_unimplemented` ledger is down to `BugReportWithOpts` and `DialTCP`/`UserDial`, and the docs-consistency gate now also fails on hand-maintained coverage rows that contradict the manifest.
- **Full gate coverage in the upstream validator**: handlers registered from build-tagged sibling files (`ipn/localapi/{cert,serve,debug}.go`, the `//go:build !ts_omit_x` pattern) are now derived too, closing the validator's skip list entirely — and immediately catching `debug-optional-features` (gated by `HasDebug` upstream, not core).
- **Documentation as a product** (post-review overhaul):
  - `Documentation/INTEGRATING.md` is the canonical integration guide; the Claude skill, new root `AGENTS.md`, new `.github/copilot-instructions.md`, and an `llms.txt` (served at the DocC site root) are thin adapters pointing at it.
  - `Documentation/endpoints.json` — machine-readable manifest of every implemented endpoint (Swift symbol, read/write risk, feature gate, min/tested tailscaled versions, transports, stability); `Scripts/generate-endpoint-docs.py` renders the coverage and quick-reference tables from it, enforced by CI.
  - Five task-oriented recipe articles (menu-bar status app, monitoring without polling, exit-node control, Serve + certificates, testing with mocks) whose every Swift snippet is an excerpt of the new compiled `Examples/Recipes` package — `Scripts/check-recipe-snippets.py` fails CI on drift, and CI builds and tests the package on macOS and Linux.
  - `Scripts/check-release-consistency.sh`: CI and the release workflow fail when README, DocC, the agent skill, coverage metadata, CLAUDE.md, CHANGELOG, and the release tag disagree on the version — and now also when any doc disagrees with the source on the default capability version. Written for Bash 3.2 (macOS system bash) and exercised in the macOS CI job so the release-time path can't rot.
- README restructured task-first: install line and task sections (status, watch, safe writes, Serve) directly after the tool-choice table; a runtime-support matrix separating "builds" from "connects to a daemon"; history trimmed to the CHANGELOG.

### Breaking

- `TailscaleClientError` gained cases (`.permissionDenied`, `.rateLimited`, `.peerNotFound`); exhaustive switches need new arms. HTTP 403 responses that previously surfaced as `.unexpectedStatus(403, …)` now throw `.permissionDenied`, and a `whois(address:)` miss that previously surfaced as `.unexpectedStatus(404, …)` now throws `.peerNotFound`.
- The default advertised capability changed from `1` to `144`. Daemon behavior gated on capability may differ; pin `capabilityVersion: 1` or set `TAILSCALE_LOCALAPI_CAPABILITY=1` to restore the old wire behavior.
- `setAuditReason(_:)` (introduced unreleased) was replaced by the task-scoped `TailscaleClient.withAuditReason(_:operation:)` before ever shipping: client-global reasons could cross-contaminate concurrent operations.
- `ClientVersionStatus.runningLatest` changed from `Bool?` to `Bool` (with `urgentSecurityUpdate` and `notify` added as non-optional): upstream marks these `omitempty`, so `false` is simply absent on the wire — an optional would decode real answers as `nil`.

### Deprecated

- `addProfile()` is now a deprecated alias of `switchToEmptyProfile()` — the upstream-aligned name for the same `PUT /profiles/` operation is canonical.

### Fixed

- Version drift: DocC *Getting Started* recommended 0.7.0; the coverage matrix identified itself as 0.9.0; CONTRIBUTING.md declared the (shipped) CLI out of scope.

## [0.10.0] - 2026-08-03

### Added

- **Serve, Funnel & certificates** (`ServeAndFunnel` DocC article):
  - `serveConfig()` / `setServeConfig(_:)` wrap `GET`/`POST /localapi/v0/serve-config` with ETag optimistic concurrency — the snapshot carries the daemon's `Etag` header in `ServeConfig.etag`, writes replay it as `If-Match`, and a stale write throws the new `TailscaleClientError.preconditionFailed(body:endpoint:)` (re-fetch, re-apply, retry). New `ServeConfig`/`TCPPortHandler`/`WebServerConfig`/`HTTPHandler`/`ServiceConfig` models mirror `ipn.ServeConfig` as a tolerant subset.
  - `certDomains()`, `certPEM(domain:kind:minValidity:)`, and `certPair(domain:minValidity:)` wrap `cert-domains` and the `cert/<domain>` prefix (pair splitting matches upstream's key-then-certs layout; unsplittable pairs fail closed).
  - `setDNS(name:value:)` (ACME DNS-01 TXT records) and `queryFeature(_:)` (`QueryFeatureResponse` control-plane probe for serve/funnel enablement).
  - CLI: `serve status` and `cert domains`, both with `--json`.
  - Integration write lane proves the concurrency contract against a real daemon: a round-trip write plus a deliberately stale-ETag write that must be rejected with 412.

- `dnsConfig()` wraps `GET /localapi/v0/dns-config` (requires Tailscale 1.98+; older daemons surface as `endpointUnavailable`, exercised by the new previous-stable CI lane) — the tailnet's DNS *intent* from the netmap (`DNSConfig`/`DNSRecord` models: resolvers, split-DNS routes, MagicDNS proxying, cert domains, extra records), complementing `dnsOSConfig()`'s installed state.
- Hermetic headscale nightly now runs a tailscaled version matrix: stable, previous-stable (pinned), and unstable.
- Hostile-transport test suite: a real Unix fault server exercises accept-then-silence (unary + streaming deadlines, with independent watchdogs so a regressed deadline fails fast instead of hanging CI), missing/refused sockets, and non-200 streaming heads; CLI black-box tests run the built binary to pin `login --timeout` behavior and `watch --json` NDJSON framing; discovery staleness selection is tested with injected probes.
- CI: a Thread Sanitizer lane (Linux) runs the unit suite under TSan to catch data races in the concurrency-heavy transport and test-harness code.

### Breaking

- `IPNNotify.loginFinished` changed from `Bool?` to `EmptyMessage?` to match the wire format (upstream sends `{}` as a presence marker). Replace `if notify.loginFinished == true` with `if notify.loginFinished != nil`.

### Fixed

- `checkPrefs(_:)` now decodes its response **strictly** and fails closed: daemon-reported failures (HTTP 200 + `Error` field, previously discarded entirely) throw with the daemon's reason, and a malformed 200 body throws `.decoding` instead of silently passing validation.
- Unix-socket unary requests now poll with cancellation checks and bridge task cancellation into the transport, so `requestTimeout` interrupts a daemon that accepts but never answers.
- Unix-socket streaming now connects and validates the HTTP response head *before* `watchIPNBus()`/`logtap()` return, restoring the promised throw-on-connect-failure semantics.
- CLI `login --timeout` races a real timer against the IPN bus (a silent bus now times out) and rejects non-positive values.
- `routeAll` documentation corrected: it accepts advertised subnet routes (`--accept-routes`); exit-node routing is separate.
- macOS App Store discovery: the Group Containers fallback no longer recursively scans all containers — it shallow-scans Tailscale's own, orders candidates newest-first, and liveness-probes each with an authenticated status request before selecting (stale proof files are skipped).
- CLI `watch --json` emits compact NDJSON (ISO 8601 dates) with diagnostics on stderr, making it machine-parseable.
- `NotifyWatchOpt.allInitial` now includes `initialDriveShares` and `initialOutgoingFiles`.
- `DNSConfig.routes` tolerates JSON `null` route values (Go nil slices, seen against a live daemon).
- `DNSConfig.exitNodeFilteredSet` documentation corrected: entries are DNS names the exit node's DNS proxy must not answer (leading-dot entries are suffix matches, others exact) — not CIDR prefixes.

### Changed

- CI coverage floor ratcheted from 55% to 70% (latest measured: 79.2% on macOS).

## [0.9.0] - 2026-08-03

### Added

- **Auth & profiles**: `loginInteractive()` (BrowseToURL arrives on the IPN bus — see the new *Login Flow* article), `logout()` and `resetAuth()` (destructive; wire-shape unit tests only, never integration-tested), the `profiles/` family (`profiles()`, `currentProfile()`, `addProfile()`, `switchProfile(_:)`, `deleteProfile(_:)` with new `LoginProfile`/`NetworkProfile` models), and `idToken(audience:)` (OIDC token as raw control-plane JSON).
- **Experimental GUI contract**: `experimental.setGUIVisible(_:sessionID:)`, `.setPushDeviceToken(_:)`, and `.handlePushMessage(_:)` — the endpoints Tailscale's own GUI clients use (SemVer-exempt).
- CLI: `login` (streams the IPN bus and prints the auth URL), `logout --yes` (guarded), and `switch` (list profiles or switch by ID).
- DocC article *The Login Flow*: subscribe-then-start ordering, headless auth-key bring-up, profile lifecycle, and handling the destructive pair.

## [0.8.0] - 2026-08-03

### Added

- DocC article *Writing Safely*: mask semantics, validate-before-apply, purpose-built endpoints over raw edits, and the hermetic write-testing pattern.
- CLI: `set exit-node <stableID>` (with `--allow-lan-access`), `set shields-up <bool>`, and `set accept-routes <bool>` — the write APIs from the command line, with `--json` echoing the updated prefs.

### Added

- **First write APIs**: `editPrefs(_:)` applies a partial preferences update via `PATCH /localapi/v0/prefs` using the new typed `MaskedPrefs` builder — setting a property encodes both the value and its `<Name>Set` mask flag, so partial updates cannot be malformed; `checkPrefs(_:)` validates a full `Prefs` without applying; `setUseExitNode(enabled:)` toggles the selected exit node without forgetting it.
- **Daemon control**: `setExpirySooner(_:)` (key hygiene), `reloadConfig()` (config-file daemons, typed `ReloadConfigResult`), and `start(options:)` (backend start incl. headless auth-key bring-up via `StartOptions`); raw endpoints now accept any 2xx (`start` answers 204).
- Write-API integration tests are double-gated: `TAILSCALE_INTEGRATION_WRITE=1` is set only in the hermetic headscale workflow, never on the self-hosted runner's real tailnet.

## [0.7.0] - 2026-08-02

### Added

- **DNS diagnostics**: `dnsOSConfig()` (nameservers, search + split-DNS match domains), `dnsQuery(name:type:)` (resolves through tailscaled's forwarder — the MagicDNS path — returning the raw RFC 1035 answer plus the chosen resolvers), and `checkIPForwarding()` (subnet-router/exit-node preflight with an `isReady` convenience).
- **Lookups**: `peer(byID:)` fetches a peer's full `tailcfg.Node` by numeric ID (reusing `WhoIsNode`, which gains `homeDERP`); `userProfile(byID:)` resolves numeric `UserID` references (`UserProfile` gains `groups`). For both, 404 means "not in the netmap" — deliberately not `endpointUnavailable`.
- **Experimental namespace debuts** (`client.experimental`, exempt from SemVer per the stability tiers): `bugreport(note:diagnose:record:)`, `goroutines()`, and streaming `logtap()` (`AsyncThrowingStream<LogtapEntry, Error>`, non-JSON lines tolerated).
- CLI: `dns status`, `dns query <name> [--type]`, and `check-forwarding` subcommands (all with `--json`; `check-forwarding` exits non-zero when the host is not ready).
- CI now reports the CLI's footprint (binary size and peak RSS) in the self-hosted integration job.
- **DocC article set**: Getting Started, Discovery & Permissions (the TCC tradeoff), Streaming Guide, Error Handling (including the two meanings of 404), Experimental APIs & Stability Tiers, and Version Compatibility (known daemon-version edges) — published with the hosted documentation.

### Fixed

- Coverage matrix: `routecheck` is not a standalone LocalAPI endpoint — route probing is the `?probe=true` hook behind `suggest-exit-node`, already wrapped by `suggestExitNode(forceProbe:)`.

## [0.6.0] - 2026-08-02

### Added

- **DERP map**: `derpMap()` wraps `GET /localapi/v0/derpmap` with typed `DERPMap`/`DERPHomeParams`/`DERPRegion`/`DERPNode` models (int-keyed region map, Go port conventions exposed via `effectiveSTUNPort`/`effectiveDERPPort`).
- **Exit node suggestion**: `suggestExitNode(forceProbe:)` wraps `/localapi/v0/suggest-exit-node` (`ExitNodeSuggestion` + `NodeLocation` models). Defaults to GET for compatibility with older daemons; `forceProbe: true` POSTs `?probe=true` (Tailscale 1.86+) to re-measure before answering.
- **User metrics**: `userMetrics()` wraps `GET /localapi/v0/usermetrics` — the stable, documented Prometheus metrics behind `tailscale metrics print`, distinct from the internal `metrics()` counters.
- Optional endpoints now also map HTTP 501 (feature compiled out of the daemon build) to `TailscaleClientError.endpointUnavailable`, alongside 404.
- **Native Swift netcheck**: `client.netcheck()` (and the standalone `Netcheck` runner) STUN-probes every region in the DERP map over UDP — no daemon involvement beyond fetching the map — and reports per-region latency, the preferred DERP region, this machine's public IPv4/IPv6 endpoints, whether UDP works at all, and whether the NAT mapping varies by destination (the "hard NAT" signature). Includes a pure-Swift RFC 8489 STUN binding codec (XOR-MAPPED-ADDRESS incl. legacy 0x8020 and plain MAPPED-ADDRESS fallback), unit-tested without a network.
- **CLI as a product**: `tailscale-swift` is now an executable product (`swift build --product tailscale-swift`), with new `derpmap`, `suggest-exit`, `netcheck`, and `usermetrics` subcommands and `--json` on every subcommand with a structured result. A Homebrew tap formula template ships in `Documentation/HOMEBREW.md`.
- **Models are fully `Codable`**: the status/whois/ping families gained the encode side (synthesized from existing `CodingKeys`; `CapabilityValue` writes its wire form by hand), so responses can be re-serialized for `--json` output, caching, or snapshots.
- **`Examples/StatusDemo`**: a standalone SPM package consuming the library via a path dependency — built on macOS and Linux CI and *run* against a real daemon in the self-hosted integration workflow.
- Release automation now attaches CLI binaries (macOS universal, Linux x86_64) to each GitHub Release.

### Changed

- Tested against Tailscale 1.98 (macOS) and the current stable tailscaled on Linux (headscale hermetic CI).

## [0.5.0] - 2026-08-02

### Added

- **Linux support for the Unix socket transport**: the POSIX socket code now compiles and runs on Glibc platforms (SIGPIPE suppressed via `MSG_NOSIGNAL`; poll-based reads honor task cancellation even when the daemon is silent). `MacClientInfo` and interface discovery remain Darwin-only; loopback *streaming* via URLSession is unavailable on Linux (corelibs has no `URLSession.bytes`), which only affects the Darwin-specific GUI-token flow anyway.
- **Testable wire-format parsers** extracted from the socket transport: `HTTPWireFormat` (request serialization + response-head parsing), `HTTPHeadBuffer`, `NewlineFramer`, and an incremental `ChunkedTransferDecoder` — with a corner-case suite covering split-anywhere chunk boundaries, trailers, chunk extensions, bare-LF tolerance, >1 MB payloads, oversized heads, and UTF-8 frames split across reads. Library line coverage rose from 56.8% to 66.9%.
- CI: Linux build+test job (swift:6.1 container); nightly hermetic integration workflow running the live suite against headscale + real tailscaled (userspace networking) — no secrets, throwaway tailnet.
- Release automation: tag-triggered GitHub Releases with notes extracted from this file, plus a backfill workflow for historical tags.

## [0.4.0] - 2026-08-02

### Fixed

- `CapabilityValue` now decodes any valid `CapMap` payload instead of failing the entire `status()`/`whois()` response. Upstream defines capability values as arrays of arbitrary JSON; boolean arrays (e.g. `"default-auto-update": [false]` on Tailscale 1.98) decode as the new `.booleans` case, and anything else (objects, mixed arrays) decodes losslessly as `.raw([JSONValue])`. Found by running the integration suite against a live daemon.

### Added

- **`TailscaleClientMocks` library product**: public `MockTransport` (scriptable unary responses and line streams with delays, injected errors, and per-connection scripts) and `RequestRecorder`, so apps can test their Tailscale-facing code without a daemon. The package's own tests now use it.
- **Capability probing**: `daemonFeatures()` wraps `POST /localapi/v0/debug-optional-features` (`OptionalFeatures` model). Endpoint availability is build-dependent in modern tailscaled; probe instead of guessing.
- **Request deadlines**: `TailscaleClientConfiguration.requestTimeout` (default 30 s, `nil` disables) applied to unary requests and stream establishment; new `TailscaleClientError.timeout` case.
- New `TailscaleClientError.endpointUnavailable(endpoint:feature:)` case for optional endpoints missing from the connected daemon build.
- **IPN bus streaming hardening**: undecodable lines are skipped and reported via the new `onUndecodableLine` callback instead of killing the stream; opt-in auto-reconnect with exponential backoff via `IPNBusReconnectPolicy`.
- **`IPNNotify` completed**: `prefs`, `netMap` (lossless `JSONValue`), `incomingFiles`/`outgoingFiles` (new `PartialFile`/`OutgoingFile` models), and `filesWaiting` — the `.initialPrefs`/`.initialNetMap` watch options are now safe to request.
- Public memberwise initializers and `Equatable` on all response models (SwiftUI previews, consumer tests); `Prefs` family is now `Codable`.
- `LocalAPIDiscovery` is now public so apps can report how the daemon was found.
- CLI: new `tailscale-swift features` command (`--json` supported).
- CI: iOS/tvOS/watchOS build checks, SPM caching, strict format linting, and a coverage floor (measured baseline 56.8%)
- CI: real-daemon integration workflow on a self-hosted macOS runner (fork-guarded; discovers the LocalAPI via `tailscale debug local-creds` with socket and sameuserproof fallbacks)

### Changed

- All requests now send `Host: local-tailscaled.sock` (upstream's `validHost` requirement), matching the Go client; previously only the unix-socket transport did.
- The stray debug print in the IPN bus hot path is gone.

## [0.3.1] - 2025-01-14

### Changed

#### LocalAPI Discovery
- **Unix socket discovery now takes priority** over macOS App Store loopback discovery
  - Avoids triggering macOS TCC permission popup for Group Container access
  - Works seamlessly with Homebrew (`brew install tailscale`) and standalone `tailscaled`
- **macOS App Store discovery is now opt-in** via `allowMacOSAppStoreDiscovery` flag
  - `TailscaleClientConfiguration.default` no longer triggers TCC popups
  - Use `.default(allowMacOSAppStoreDiscovery: true)` to enable App Store GUI discovery
  - Clear documentation warns about TCC popup behavior

#### Transport
- **Added HTTP chunked transfer encoding support** for Unix socket transport
  - Fixes compatibility with Homebrew `tailscaled` which uses chunked responses
  - Both regular requests and streaming (IPN bus) now properly decode chunked data

### Added

#### Socket Paths
- **Homebrew socket path**: `/var/run/tailscaled.socket` added to discovery candidates
  - First in priority order for seamless Homebrew experience

### Fixed
- Unix socket transport now correctly parses chunked HTTP responses
- Streaming endpoints work correctly with chunked transfer encoding

## [0.3.0] - 2025-01-14

### Added

#### IPN Bus Streaming
- **`/localapi/v0/watch-ipn-bus`** - Real-time state change notifications
  - `watchIPNBus(options:)` async method returning `AsyncThrowingStream<IPNNotify, Error>`
  - Eliminates polling - get instant notifications when Tailscale state changes
  - `IPNNotify` model with state, engine stats, health, suggested exit node
  - `IPNState` enum (NoState, InUseOtherUser, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running)
  - `EngineStatus` model with traffic bytes, live peers, DERP connection count
  - `HealthState` and `HealthWarning` models for health monitoring
  - `NotifyWatchOpt` option set for controlling notification types
- **Streaming transport support** - New `sendStreaming` method on `TailscaleTransport` protocol
  - Supports both URLSession (loopback) and Unix socket transports
  - Line-based JSON streaming for newline-delimited responses

#### CLI Features
- `tailscale-swift watch` - Stream live IPN bus notifications
  - `--json` flag for raw JSON output
  - `--engine` flag to include traffic statistics
  - `--all-initial` flag to include all initial state

#### Testing
- 18 new unit tests for IPN bus models and decoding
- Updated MockTransport to support streaming protocol

## [0.2.1] - 2025-12-01

### Added

#### Network Interface Discovery
- **`NetworkInterfaceDiscovery`** - Identify which TUN interface Tailscale is using
  - Uses BSD `getifaddrs` API to enumerate system network interfaces
  - Matches Tailscale IPs against system interfaces to find the TUN (e.g., `utun16`)
  - `InterfaceInfo` struct with name, address, IPv6 flag, and interface state flags
- **`StatusResponse.interfaceName`** - Convenient computed property returning interface name
- **`StatusResponse.interfaceInfo`** - Full interface details including up/running/point-to-point state

#### Testing
- 17 new unit tests for interface discovery
- 3 new integration tests validating interface discovery against live daemon

## [0.2.0] - 2025-12-01

### Added

#### New Endpoints
- **`/localapi/v0/whois`** - Identity lookup by Tailscale IP or node key
  - `WhoIsResponse`, `WhoIsNode`, `WhoIsHostinfo` models
  - Look up user profile and node info for any peer
- **`/localapi/v0/prefs`** - Read current node preferences
  - `Prefs`, `AutoUpdatePrefs`, `AppConnectorPrefs` models
  - Exit node, DNS, SSH, shields-up, advertised routes configuration
- **`/localapi/v0/ping`** - Network connectivity diagnostics
  - `PingResult`, `PingType` models
  - Support for disco, TSMP, ICMP, and peerAPI ping types
  - Latency measurement with human-readable formatting
  - Direct vs DERP relay detection
- **`/localapi/v0/metrics`** - Internal Tailscale metrics
  - Returns Prometheus exposition format
  - Useful for monitoring and observability

#### CLI Commands
- `tailscale-swift whois <ip>` - Look up identity for a Tailscale IP
- `tailscale-swift prefs` - Display current node preferences
- `tailscale-swift ping <ip> [-c count] [-t type]` - Test connectivity with latency stats
- `tailscale-swift health` - Display health warnings from status
- `tailscale-swift metrics [--filter pattern]` - Show internal metrics

#### Testing
- Comprehensive unit tests for all new models (WhoIsResponse, Prefs, PingResult)
- Error handling tests covering all error types and recovery suggestions
- Expanded integration tests (17 tests covering all endpoints)
- Test coverage improved from 44% to 66%

### Changed

#### LocalAPI Discovery
- **Replaced lsof shell-out with pure Swift libproc implementation**
  - Uses `proc_pidinfo` and `proc_pidfdinfo` Darwin APIs
  - ~10x faster (~5ms vs ~50ms)
  - No subprocess spawning
  - Added `TAILSCALE_SKIP_LIBPROC=1` env var for fallback

### Fixed
- Documentation updated to reflect all v0.2.0 capabilities
- DocC catalog reorganized with proper topic groupings

## [0.1.1] - 2025-12-01

### Improved

#### Error Handling
- Added specific transport error types for better diagnostics:
  - `socketNotFound(path:)` - Unix socket doesn't exist
  - `connectionRefused(endpoint:)` - Daemon not listening
  - `malformedResponse(detail:)` - HTTP response parsing failed
- Added endpoint context to `unexpectedStatus` and `decoding` errors
- Added `bodyPreview` property on `TailscaleClientError` for debugging (truncates to 500 chars)
- Implemented `LocalizedError` protocol with `recoverySuggestion` for all error types
- Human-readable error descriptions with actionable guidance

#### CLI Exit Node Display
- Display active exit node prominently when routing through one
- Show connection quality details:
  - Connection type (direct IP:port vs DERP relay)
  - DERP relay location when applicable
  - Last WireGuard handshake time
  - Traffic statistics (rx/tx bytes with human-readable formatting)
- List available exit nodes in verbose mode

### Fixed
- Transport errors now pass through specific error types instead of wrapping all errors in `networkFailure`

## [0.1.0] - 2025-09-30

### Added

#### Core Library
- `TailscaleClient` actor with async/await API for querying Tailscale status
- Full `/localapi/v0/status` endpoint implementation with comprehensive Swift models
- `StatusResponse`, `NodeStatus`, `UserProfile`, `TailnetStatus`, `BackendState` and supporting types
- `StatusQuery` for controlling response detail (peers, dashboard flags)
- Strict Swift 6 concurrency with complete `Sendable` conformance
- Actor-based isolation for thread safety

#### Transport & Discovery
- Protocol-oriented `TailscaleTransport` abstraction
- `URLSessionTailscaleTransport` with Unix socket and TCP loopback support
- macOS LocalAPI discovery with filesystem scanning of Group Containers
- Custom Unix socket transport using CFSocket on Darwin platforms
- Automatic injection of `Tailscale-Cap` header and Basic Auth when needed

#### Configuration
- `TailscaleClientConfiguration` with flexible overrides
- Environment variable support:
  - `TAILSCALE_LOCALAPI_SOCKET` - Override Unix socket path
  - `TAILSCALE_LOCALAPI_PORT` / `TAILSCALE_LOCALAPI_HOST` - TCP loopback config
  - `TAILSCALE_LOCALAPI_URL` - Full base URL override
  - `TAILSCALE_LOCALAPI_AUTHKEY` - Authentication token
  - `TAILSCALE_LOCALAPI_CAPABILITY` - Capability version override
  - `TAILSCALE_DISCOVERY_DEBUG` - Debug logging for discovery process
  - `TAILSCALE_SAMEUSER_PATH` - Explicit sameuserproof file path
  - `TAILSCALE_SAMEUSER_DIR` - Restrict filesystem scanning
- Pluggable transport for testing and custom implementations

#### Development CLI
- `tailscale-swift` executable for development and testing
- `status` subcommand with basic and `--verbose` modes
- Built with Swift Argument Parser for comprehensive help
- Man page in groff format (`Documentation/man/tailscale-swift.1`)
- CLI README with usage examples and extension guide

#### Testing & Quality
- Comprehensive unit test suite with mock transports
- Integration tests for live daemon testing (opt-in via `TAILSCALE_INTEGRATION=1`)
- JSON fixtures from real Tailscale responses
- GitHub Actions CI workflow for macOS testing
- Swift format with zero violations
- GitHub Actions DocC deployment workflow

#### Documentation
- Complete DocC API documentation
- GitHub Pages deployment at https://dweekly.github.io/swift-tailscale-client/
- Comprehensive README with quickstart and configuration guide
- CONTRIBUTING.md with development guidelines
- CODE_OF_CONDUCT.md and SECURITY.md
- SPDX license headers on all source files
- Distinction from TailscaleKit clearly documented

#### Project Infrastructure
- Swift Package Manager support for macOS 13+, iOS 16+, tvOS 16+, watchOS 9+
- MIT license with clear unofficial status disclaimers
- Semantic versioning with v0.1.0 tag
- Comprehensive .gitignore for Swift projects
