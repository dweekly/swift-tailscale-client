# LocalAPI Coverage

Complete inventory of the Tailscale LocalAPI surface and this package's position on every endpoint: implemented, planned (with target version), experimental, or deliberately unsupported (with the reason).

<!-- BEGIN GENERATED: coverage-provenance (Scripts/generate-endpoint-docs.py) -->
**Last updated:** 2026-11-21
**Upstream reference:** `tailscale/tailscale` pinned commit `1db8e79a8b00` (verified 2026-11-21; full SHA and validation in [`endpoints.json`](endpoints.json)), `ipn/localapi/` + `client/local/`
<!-- END GENERATED: coverage-provenance (Scripts/generate-endpoint-docs.py) -->
**swift-tailscale-client version:** 1.0.0

Tiers are defined in [`ROADMAP.md`](../ROADMAP.md#stability--support-tiers): **Stable** (methods on `TailscaleClient`, SemVer-protected post-1.0), **Experimental** (`client.experimental`, exempt from SemVer), **Unsupported** (documented, not wrapped).

**Two independent stability axes.** *Upstream maturity* is Tailscale's own per-method "API maturity" annotation for the daemon endpoint (`stable` / `unstable` / `unspecified` — upstream documents that unannotated methods must be assumed unstable). *Swift support* is this package's promise for its façade. A **supported Swift façade over an upstream-unstable endpoint means we normalize upstream drift** (tolerant decoding, typed skips, compatibility testing) — it never implies Tailscale guarantees the wire contract.

---

## How the LocalAPI is put together (read this first)

Three upstream facts shape everything below:

1. **Endpoint availability is build-dependent.** Since the daemon was modularized, only ~21 handlers are always registered; the rest are attached at `init()` time by optional `feature/*` packages and build-tag-gated code. A size-trimmed tailscaled returns 404 for endpoints this table lists. `POST /localapi/v0/debug-optional-features` reports which optional features a daemon was compiled with — this package's capability-probing strategy (planned `daemonFeatures()`, v0.4.0) is built on it.
2. **Routing is exact-match with one level of prefix fallback.** The suffix after `/localapi/v0/` is looked up exactly; on a miss it is truncated at the first `/` and looked up again. Only `cert/`, `files/`, `file-put/`, `profiles/`, and `policy/` are true prefixes. Keys like `tka/status` and `update/check` are exact entries that happen to contain a slash.
3. **The `Host` header must be empty or `local-tailscaled.sock`.** A loopback/`localhost` Host is only accepted when the daemon requires basic auth (the Windows/token path). Upstream also warns that LocalAPI paths are "not necessarily stable APIs" — hence the tier system.

---

## Summary

<!-- BEGIN GENERATED: coverage-summary (Scripts/generate-endpoint-docs.py) -->
| Category | Count |
|----------|-------|
| Implemented (from `endpoints.json`) | 37 supported + 5 experimental |
| Planned Stable | ~40 |
| Planned Experimental | ~15 |
| Unsupported (documented, with reasons) | 6 |
| No LocalAPI equivalent (client-side features) | netcheck (implemented client-side in v0.6.0 as `Netcheck`), captive portal detection |
<!-- END GENERATED: coverage-summary (Scripts/generate-endpoint-docs.py) -->

---

## Implemented

Generated from [`endpoints.json`](endpoints.json) — the machine-readable manifest of everything this package wraps. Edit the JSON, run `Scripts/generate-endpoint-docs.py`, and CI enforces the sync.

<!-- BEGIN GENERATED: implemented-endpoints (Scripts/generate-endpoint-docs.py) -->
| Endpoint | Method(s) | Swift API | Access | Upstream maturity | Swift support | Gate | Since | Min tailscaled | Unit | Source | Live on 1.x | Pre-1.0 matrix | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `status` | GET | `status(query:)` | read | stable | supported | core | v0.1.0 | not established | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | ?peers=false via StatusQuery; interfaceName/interfaceInfo derived client-side |
| `services` | GET | `services()` | read | unspecified | supported | core | v0.12.0 | recent (VIP services era; older daemons -> endpointUnavailable) | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.102.4, 1.103.229 (read) | Tailscale Services (VIP services) keyed by svc: name; Ports are upstream ProtoPortRange text forms. Testing: a 503 without a netmap, or endpointUnavailable on daemons without the endpoint, is treated as a skip |
| `whois` | GET | `whois(address:), whois(address:protocol:), whois(nodeKey:), whois(address:scopedToDestination:), whois(address:forService:)` | read | stable | supported | core | v0.2.0 | not established | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | all stable variants wrapped; a peer miss (404) throws typed .peerNotFound |
| `prefs` | GET, PATCH | `prefs(), editPrefs(_:)` | write | stable | supported | core | v0.2.0 | not established | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read+write) | PATCH takes typed MaskedPrefs value+Set flag pairs (v0.8.0) |
| `ping` | POST | `ping(ip:type:size:)` | read | unspecified | supported | core | v0.2.0 | not established | captured fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | disco/TSMP/ICMP/peerAPI ping types |
| `metrics` | GET | `metrics()` | read | unspecified | supported | HasClientMetrics || HasDebug | v0.2.0 | not established | wire shape | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | Prometheus text; internal counters, names may churn upstream |
| `usermetrics` | GET | `userMetrics()` | read | unspecified | supported | HasUserMetrics | v0.6.0 | 1.78 | wire shape | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | stable user-facing metrics (tailscale metrics print) |
| `watch-ipn-bus` | GET (stream) | `watchIPNBus(options:reconnect:onUndecodableLine:), watchIPNBusEvents(options:retryPolicy:bounds:onUndecodableLine:)` | read | unstable | supported | HasIPNBus | v0.3.0 | not established | wire shape | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read+write) | NDJSON stream; skip-and-report on malformed lines, opt-in reconnect (v0.4.0). Upstream: our Swift facade normalizes and tolerates shape drift |
| `debug-optional-features` | POST | `daemonFeatures()` | read | unspecified | supported | HasDebug | v0.4.0 | 1.86 | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | capability probe: which optional features this daemon was built with |
| `derpmap` | GET | `derpMap()` | read | stable | supported | core | v0.6.0 | not established | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | relay regions/nodes; feeds the client-side netcheck |
| `suggest-exit-node` | GET | `suggestExitNode(forceProbe:)` | read | unspecified | supported | HasUseExitNode | v0.6.0 | not established (POST probe: 1.86) | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | — | empty 200 body = no candidates. Testing: headscale matrix lanes returned an empty suggestion (skip) |
| `dns-osconfig` | GET | `dnsOSConfig()` | read | unstable | supported | HasDNS | v0.7.0 | not established | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | — | installed OS DNS state; 500 on userspace-networking daemons. Testing: userspace-networking daemons answer 500, which the tests treat as a skip |
| `dns-query` | GET | `dnsQuery(name:type:)` | read | unspecified | supported | HasDNS | v0.7.0 | not established | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | raw RFC 1035 answer bytes + chosen resolvers |
| `check-ip-forwarding` | GET | `checkIPForwarding()` | read | unstable | supported | HasAdvertiseRoutes | v0.7.0 | not established | wire shape | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | subnet-router/exit-node preflight |
| `check-udp-gro-forwarding` | GET | `checkUDPGROForwarding()` | read | unstable | supported | HasAdvertiseRoutes | v0.11.0 | not established | wire shape | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | Linux subnet-router/exit-node performance preflight. Upstream: annotated unstable upstream despite its diagnostic role - not a stable-parity item |
| `dns-config` | GET | `dnsConfig()` | read | unspecified | supported | core | v0.10.0 | 1.98 | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.102.4, 1.103.229 (read) | tailnet DNS intent from the netmap; older daemons → endpointUnavailable. Testing: the 1.96.4 matrix lane answered endpointUnavailable (skip) |
| `peer-by-id` | GET | `peer(byID:)` | read | unspecified | supported | core | v0.7.0 | ~1.98 | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.102.4, 1.103.229 (read) | 404 = not in netmap OR daemon predates the endpoint — indistinguishable. Testing: the 1.96.4 matrix lane answered 404 for a known node ID (daemon predates the endpoint; skip) |
| `user-profile` | GET | `userProfile(byID:)` | read | stable | supported | core | v0.7.0 | ~1.98 | wire shape | gate, maturity | — | — | 404 = unknown user OR older daemon — indistinguishable. Testing: the integration test calls it only when whois returns a user ID, and the run log does not show whether that branch ran |
| `check-prefs` | POST | `checkPrefs(_:)` | read | unspecified | supported | core | v0.8.0 | not established | wire shape | gate, maturity | — | 1.96.4, 1.102.4, 1.103.229 (read+write) | fails closed: daemon-reported Error throws; malformed 200 throws .decoding |
| `set-use-exit-node-enabled` | POST | `setUseExitNode(enabled:)` | write | stable | supported | HasUseExitNode | v0.8.0 | not established | wire shape | gate, maturity | — | — | toggles without forgetting the selected exit node |
| `set-expiry-sooner` | POST | `setExpirySooner(_:)` | write | unstable | supported | core | v0.8.0 | not established | wire shape | gate, maturity | — | — | key hygiene; shortens node-key expiry. Upstream: upstream files this under debug |
| `reload-config` | POST | `reloadConfig()` | write | unspecified | supported | core | v0.8.0 | not established | wire shape | gate, maturity | — | — | only meaningful for config-file daemons |
| `start` | POST | `start(options:) / startFreshProfile(controlURL:authKey:)` | write | unspecified | supported | core | v0.8.0 | not established | wire shape | gate, maturity | — | 1.96.4, 1.102.4, 1.103.229 (read+write) | backend start / headless auth-key bring-up; 204 on success |
| `login-interactive` | POST | `loginInteractive()` | write | stable | supported | core | v0.9.0 | not established | wire shape | gate, maturity | — | 1.96.4, 1.102.4, 1.103.229 (read+write) | BrowseToURL arrives on the IPN bus — subscribe before calling |
| `logout` | POST | `logout()` | destructive | unspecified | supported | core | v0.9.0 | not established | wire shape | gate, maturity | — | 1.96.4, 1.102.4, 1.103.229 (read+write) | disconnects and expires the node key |
| `shutdown` | POST | `shutdownTailscaled()` | destructive | unstable | supported | core | v0.12.0 | recent (older daemons -> endpointUnavailable) | wire shape | gate, maturity | — | — | graceful daemon exit; requires write access AND the AllowTailscaledRestart policy (403 -> .permissionDenied). Testing: destructive: terminates the daemon, so no integration test calls it |
| `update/check` | GET | `checkUpdate()` | read | stable | supported | HasClientUpdate | v0.11.0 | not established | wire shape | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | reports update availability only; installs nothing |
| `disconnect-control` | POST | `disconnectControl()` | write | stable | supported | HasDebug || HasAdvertiseRoutes | v0.11.0 | not established | wire shape | gate, maturity | — | — | administrative: drains HA subnet-router/app-connector replicas before shutdown. Testing: drops the control connection, so no integration test calls it |
| `reset-auth` | POST | `resetAuth()` | destructive | unspecified | supported | core | v0.9.0 | not established | wire shape | gate | — | — | wipes auth state for re-login. Upstream: no public Go client method |
| `profiles/` | GET, PUT, POST, DELETE | `profiles(), currentProfile(), switchToEmptyProfile(), switchProfile(_:), deleteProfile(_:)` | write | unspecified (SwitchProfile: stable, SwitchToEmptyProfile: stable) | supported | core | v0.9.0 | not established | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | multi-account profile management (LoginProfile/NetworkProfile models). Upstream: mixed per-symbol maturity; switchToEmptyProfile() mirrors the upstream name (stable) |
| `id-token` | POST | `idToken(audience:)` | read | unspecified | supported | HasDebug | v0.9.0 | not established | wire shape | gate, maturity | — | — | OIDC token passed through as raw control-plane JSON. Testing: control-plane dependent |
| `serve-config` | GET, POST | `serveConfigSnapshot(), setServeConfig(_:matching:), replaceServeConfigUnconditionally(_:)` | write | unstable (SetServeConfig: unspecified) | supported | HasServe | v0.10.0 | not established (ETag: 1.40+) | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read+write) | ETag optimistic concurrency; stale writes throw .preconditionFailed. Upstream: GetServeConfig is explicitly unstable upstream; GetServeConfig is annotated unstable; SetServeConfig carries no annotation (assume unstable). Testing: the pre-1.0 matrix write tests include the stale-ETag 412 rejection |
| `cert-domains` | GET | `certDomains()` | read | stable | supported | core | v0.10.0 | not established | synthetic fixture | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.102.4, 1.103.229 (read) | null body (no HTTPS) decodes as empty list. Testing: the 1.96.4 matrix lane answered endpointUnavailable (build without ACME; skip) |
| `cert/` | GET | `certPEM(domain:kind:minValidity:), certPair(domain:minValidity:)` | read | stable | supported | HasACME | v0.10.0 | not established | wire shape | gate, maturity | — | — | first fetch may block on ACME issuance; pair split fails closed. Testing: needs an HTTPS-enabled tailnet |
| `set-dns` | POST | `setDNS(name:value:)` | write | unspecified | supported | HasACME | v0.10.0 | not established | wire shape | gate, maturity | — | — | ACME dns-01 TXT records only; control plane restricts names. Testing: control-plane rate-limited |
| `query-feature` | POST | `queryFeature(_:)` | read | unspecified | supported | HasServe | v0.10.0 | not established | wire shape | gate, maturity | 1.102.2 (read, 2026-11-22) | — | control-plane probe for serve/funnel enablement; 503 without a netmap. Testing: headscale does not implement query-feature, so the matrix lanes skip it |
| `bugreport` | POST | `bugReport(note:) (supported), experimental.bugreport(note:diagnose:record:)` | write | stable | supported | HasDebug | v0.7.0 | not established | wire shape | gate, maturity | — | — | drops a marker in the daemon log; returns the marker ID. Upstream: upstream-stable; the supported facade wraps BugReport only - BugReportWithOpts (recording lifecycle) stays in the stable-parity ledger because a faithful recording handle must hold the request body open, which this client cannot do yet |
| `goroutines` | GET | `experimental.goroutines()` | read | unspecified | experimental | core | v0.7.0 | not established | wire shape | gate, maturity | 1.102.2 (read, 2026-11-22) | 1.96.4, 1.102.4, 1.103.229 (read) | Go stack dump for diagnostics |
| `logtap` | GET (stream) | `experimental.logtap()` | read | unstable | experimental | HasLogTail | v0.7.0 | not established | wire shape | gate, maturity | — | — | live daemon log stream |
| `set-gui-visible` | POST | `experimental.setGUIVisible(_:sessionID:)` | write | unspecified | experimental | HasDebug || windows || darwin | v0.9.0 | not established | wire shape | gate | — | — | GUI-client contract; shapes follow Tailscale's own clients. Upstream: GUI-client contract; no public Go client method |
| `set-push-device-token` | POST | `experimental.setPushDeviceToken(_:)` | write | unspecified | experimental | HasDebug | v0.9.0 | not established | wire shape | gate | — | — | APNs token registration (GUI contract). Upstream: GUI-client contract; no public Go client method |
| `handle-push-message` | POST | `experimental.handlePushMessage(_:)` | write | unspecified | experimental | HasDebug | v0.9.0 | not established | wire shape | gate | — | — | delivers a push payload to the daemon (GUI contract). Upstream: GUI-client contract; no public Go client method |

Upstream maturity per Tailscale's own "API maturity" annotations in `tailscale/tailscale` 1db8e79a8b00d9ea3a7459c92df07e3d565a8811 (verified 2026-11-21); methods without an annotation must be assumed unstable, and "supported" over an upstream-unstable endpoint means this package normalizes drift — not that Tailscale guarantees the wire contract.

How to read the evidence columns:

- **Unit**: what the unit tests (`swift test`, mocked transport) decode. *Synthetic fixture*: generated or hand-written JSON under `Tests/TailscaleClientTests/Fixtures/`, never read from a daemon. *Captured fixture*: replies recorded from a real daemon, with provenance in `ping-captured.provenance.json`. *Wire shape*: request path, method, body, and inline response JSON asserted in the test.
- **Source**: compared with `tailscale/tailscale` at the pinned commit by `Scripts/verify-upstream-maturity.py` in CI: the handler gate for every endpoint, plus the API maturity where a Go client method exists. This is a source comparison, not daemon behavior.
- **Live on 1.x** (23 of 42 endpoints): a test in `TailscaleClientIntegrationTests` called the endpoint and passed against the named tailscaled version in the last successful run of the self-hosted macOS lane (Tailscale app on a real tailnet; read-only, because the write-gated tests skip there): [run 44968061763](https://github.com/dweekly/swift-tailscale-client/actions/runs/44968061763), 2026-11-22, commit `77fedf49b501`, tailscaled 1.102.2; tests executed: 45; skipped: 5; failed: 0. "—" means no 1.x run has observed the endpoint. *read+write* in either column means a write test that calls the endpoint also passed.
- **Pre-1.0 matrix**: tailscaled versions on which the headscale matrix observed the endpoint in its last successful run, on v0.12.0 code: [run 35513916288](https://github.com/dweekly/swift-tailscale-client/actions/runs/35513916288), 2026-09-20, commit `619b9dba5649`, tailscaled 1.96.4, 1.102.4, 1.103.229; tests executed: 44 per daemon plus the login-lifecycle test; skipped: 12 on 1.96.4 and 8 on each of the others; failed: 0. That workflow is manual-only and has not passed on 1.x code; these are historical observations, not current results.
<!-- END GENERATED: implemented-endpoints (Scripts/generate-endpoint-docs.py) -->

### Upstream-stable, not yet implemented

Methods Tailscale explicitly documents as stable in `client/local` that this package does not wrap yet (the stable-parity ledger; the program behind it is [issue draft 04](https://github.com/dweekly/swift-tailscale-client/blob/agent/upstream-readiness-issue-drafts/Documentation/Issue-Drafts/04-stable-localapi-parity.md)):

<!-- BEGIN GENERATED: upstream-stable-unimplemented (Scripts/generate-endpoint-docs.py) -->
| Go method | Endpoint | Note |
|---|---|---|
| `BugReportWithOpts` | `bugreport` | recording lifecycle: upstream holds the POST body open until the caller ends the recording; needs a Swift recording handle whose cancellation closes the body (the experimental record: knob ends the window immediately and says so) |
| `DialTCP / UserDial` | `dial` | raw duplex streams over HTTP upgrade; needs a Swift connection abstraction first (issue draft 04) |
<!-- END GENERATED: upstream-stable-unimplemented (Scripts/generate-endpoint-docs.py) -->

Non-endpoint features: `NetworkInterfaceDiscovery` (TUN interface via `getifaddrs`), `MacClientInfo` (opt-in macOS App Store GUI discovery).

---

## Full endpoint matrix

Gating: **core** = always registered; otherwise the upstream build feature that must be compiled in. Swift API names follow the Go `client/local` method names adapted to Swift.

### Status, identity & nodes

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `status` | GET | core | Stable | **v0.3.1** | `status(query:)` |
| `whois` | GET | core | Stable | **v0.3.1** | `whois(address:)` |
| `peer-by-id` | GET | core | Stable | **v0.7.0** | `peer(byID:)` — endpoint added upstream ~1.98; 404 = not in netmap *or* older daemon |
| `user-profile` | GET | core | Stable | **v0.7.0** | `userProfile(byID:)` — endpoint added upstream 2026; older daemons 404 the path |
| `services` | GET | core | Stable | v1.0.0 | `services()` |
| `id-token` | POST | `HasDebug` | Stable | **v0.9.0** | `idToken(audience:)` — raw control-plane JSON |

### Preferences & configuration

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `prefs` | GET, HEAD, PATCH | core | Stable | GET **v0.3.1**; PATCH **v0.8.0** | `prefs()`, `editPrefs(_:)` (typed `MaskedPrefs`) |
| `check-prefs` | POST | core | Stable | **v0.8.0** | `checkPrefs(_:)` |
| `set-use-exit-node-enabled` | POST | `HasUseExitNode` | Stable | **v0.8.0** | `setUseExitNode(enabled:)` |
| `set-expiry-sooner` | POST | core | Stable | **v0.8.0** | `setExpirySooner(_:)` — `?expiry=<unix ts>` |
| `reload-config` | POST | core | Stable | **v0.8.0** | `reloadConfig()` → `ReloadConfigResult` |
| `start` | POST | core | Stable | **v0.8.0** | `start(options:)` — minimal `StartOptions` (auth key); 204 on success |
| `prefs/service-clients` | GET, POST | `HasServiceClientPrefs` | Experimental | on demand | — (new Jul 2026) |

### Diagnostics & networking

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `ping` | POST | core | Stable | **v0.3.1** | `ping(ip:type:size:)` |
| `derpmap` | GET | core | Stable | **v0.6.0** | `derpMap()` |
| `suggest-exit-node` | GET, POST | `HasUseExitNode` | Stable | **v0.6.0** | `suggestExitNode(forceProbe:)`, `forceProbe` = POST `?probe=true` |
| `metrics` | GET | `HasClientMetrics`/`HasDebug` | Stable | **v0.3.1** | `metrics()` |
| `usermetrics` | GET | `HasUserMetrics` | Stable | **v0.6.0** | `userMetrics()` |
| `dns-osconfig` | GET | `HasDNS` | Stable | **v0.7.0** | `dnsOSConfig()` |
| `dns-query` | GET | `HasDNS` | Stable | **v0.7.0** | `dnsQuery(name:type:)` — returns DNS wire bytes + resolvers |
| `dns-config` | GET | core | Stable | **v0.9.0+** | `dnsConfig()` — netmap `tailcfg.DNSConfig`; 503 when no netmap |
| `check-ip-forwarding` | GET | `HasAdvertiseRoutes` | Stable | **v0.7.0** | `checkIPForwarding()` |
| ~~`routecheck`~~ | — | — | — | not an endpoint | Route probing is the `?probe=true` hook behind `suggest-exit-node` (wrapped by `suggestExitNode(forceProbe:)` since v0.6.0); no standalone `routecheck` handler exists upstream |
| `check-udp-gro-forwarding` / `set-udp-gro-forwarding` | GET | `HasAdvertiseRoutes` | Experimental | on demand | Linux subnet-router perf preflight |
| `debug-derp-region` | POST | debug | Experimental | on demand | probe a DERP region |

### Streaming

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `watch-ipn-bus` | GET (stream) | `HasIPNBus` | Stable | **v0.3.1** (hardening v0.4.0) | `watchIPNBus(options:)` |
| `logtap` | GET (stream) | `HasLogTail` | Experimental | **v0.7.0** | `experimental.logtap()` — `AsyncThrowingStream<LogtapEntry, Error>` |
| `debug-bus-events` | GET (stream) | debug | Experimental | on demand | eventbus events (new 2026) |
| `debug-portmap` | GET (stream) | `HasDebugPortmapper` | Experimental | on demand | UPnP/PMP/PCP probe log |

### Auth & profiles

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `login-interactive` | POST | core | Stable | **v0.9.0** | `loginInteractive()` — pair with `watchIPNBus` for `BrowseToURL` |
| `logout` | POST | core | Stable | **v0.9.0** | `logout()` — destructive; unit-tested only |
| `reset-auth` | POST | core | Stable | **v0.9.0** | `resetAuth()` |
| `profiles/` (prefix) | GET, PUT, POST, DELETE | core | Stable | **v0.9.0** | `profiles()`, `currentProfile()`, `switchToEmptyProfile()`, `switchProfile(_:)`, `deleteProfile(_:)` |
| `shutdown` | POST | core | Stable | v1.0.0 | `shutdownDaemon()` |

### Serve, Funnel & certificates

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `serve-config` | GET, POST | `HasServe` | Stable | **v0.10.0** | `serveConfigSnapshot()` → snapshot with `etag`; `setServeConfig(_:matching:)` sends `If-Match` — a stale write throws `.preconditionFailed(body:endpoint:)` (proven against a live daemon in the write lane) |
| `cert-domains` | GET | `HasACME` | Stable | **v0.10.0** | `certDomains()` — optional-endpoint gated; 404 on ACME-less builds (seen on the 1.96.4 tarball) → `endpointUnavailable` |
| `cert/<domain>` (prefix) | GET | `HasACME` | Stable | **v0.10.0** | `certPEM(domain:kind:minValidity:)` (`?type=pair\|cert\|key`), `certPair(domain:minValidity:)` splits key/cert |
| `set-dns` | POST | `HasACME` | Stable | **v0.10.0** | `setDNS(name:value:)` — ACME DNS-01 TXT |
| `query-feature` | POST | `HasServe` | Stable | **v0.10.0** | `queryFeature(_:)` — `QueryFeatureResponse` |
| `check-so-mark-in-use` | GET | core | Unsupported | — | Linux `tailscale serve` preflight internal; no Swift use case |

### Taildrop & Taildrive (post-1.0)

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `file-put/<target>/<name>` (prefix) | PUT, POST | taildrop feature | Stable | Backlog | `pushFile(...)` |
| `files/` (prefix) | GET, DELETE | taildrop feature | Stable | Backlog | `waitingFiles()`, `awaitWaitingFiles()` (`?waitfor=` long-poll), `getWaitingFile(_:)`, `deleteWaitingFile(_:)` |
| `file-targets` | GET | taildrop feature | Stable | Backlog | `fileTargets()` |
| `drive/fileserver-address` | PUT | drive feature | Stable | Backlog | `setDriveFileServerAddress(_:)` |
| `drive/shares` | GET, PUT, POST, DELETE | drive feature | Stable | Backlog | `driveShares()`, set/rename/remove |

### Tailnet Lock (post-1.0)

All 13 endpoints, wrapped under **`TailnetLock`** naming (upstream renamed from `NetworkLock`; the Go `NetworkLock*` methods are deprecated aliases). Note `tka/modify` returns **204 No Content**.

| Endpoint | Method | Tier | Status |
|----------|--------|------|--------|
| `tka/status`, `tka/log` (`?limit=`) | GET | Stable | Backlog |
| `tka/init`, `tka/modify`, `tka/sign`, `tka/disable`, `tka/force-local-disable`, `tka/affected-sigs`, `tka/wrap-preauth-key`, `tka/verify-deeplink`, `tka/generate-recovery-aum`, `tka/cosign-recovery-aum`, `tka/submit-recovery-aum` | POST | Stable | Backlog |

### GUI-client contract

The endpoints Tailscale's own GUI apps use. Nobody outside Tailscale implements these today; they matter to any serious macOS/iOS app built on this package.

| Endpoint | Method | Gating | Tier | Status | Swift API |
|----------|--------|--------|------|--------|-----------|
| `set-gui-visible` | POST | debug \|\| windows/darwin | Experimental | v0.9.0 | `experimental.setGUIVisible(_:)` |
| `set-push-device-token` | POST | debug | Experimental | v0.9.0 | `experimental.setPushDeviceToken(_:)` |
| `handle-push-message` | POST | debug | Experimental | v0.9.0 | `experimental.handlePushMessage(_:)` |
| `upload-client-metrics` | POST | `HasClientMetrics` | Unsupported | — | Tailscale-internal telemetry push |

### Self-update

| Endpoint | Method | Gating | Tier | Status |
|----------|--------|--------|------|--------|
| `update/check` | GET | `HasClientUpdate` | **Stable** | **implemented (v0.11.0)** — `checkUpdate()` |
| `update/install` | POST | `HasClientUpdate` | Experimental | on demand |
| `update/progress` | GET | `HasClientUpdate` | Experimental | on demand — often overlooked; needed to display install progress |

Note: the official CLI's `tailscale update` does *not* use these — it runs the updater in-process. These exist for GUI clients.

### Debug & introspection

| Endpoint | Method(s) | Tier | Status | Notes |
|----------|-----------|------|--------|-------|
| `debug-optional-features` | POST | **Stable** | **implemented (v0.4.0)** | `daemonFeatures()`; the capability-discovery endpoint this package's probing strategy is built on |
| `bugreport` | POST | **Stable** | **implemented** | supported `bugReport(note:)` facade (v0.11.0); `experimental.bugreport(note:diagnose:record:)` keeps the diagnose/record knobs (v0.7.0); faithful `BugReportWithOpts` recording lives in the stable-parity ledger |
| `goroutines` | GET | Experimental | **v0.7.0** | `experimental.goroutines()` |
| `debug` (`?action=`) | POST | Experimental | on demand | actions: `notify`, `rebind`, `restun`, `break-tcp-conns`, `break-derp-conns`, `force-netmap-update`, `control-knobs`, `pick-new-derp`, `force-prefer-derp`, `derp-set-homeless`, `derp-unset-homeless`, `peer-relay-servers`, `peer-disco-keys`, `rotate-disco-key`, `statedir`, `clear-netmap-cache`, `current-netmap` |
| `pprof` | GET | Experimental | on demand | |
| `component-debug-logging` | POST | Experimental | on demand | verbose logging per component for N seconds |
| `debug-packet-filter-rules` / `debug-packet-filter-matches` | POST | Experimental | on demand | |
| `debug-peer-endpoint-changes`, `debug-dial-types`, `debug-log`, `debug-rotate-disco-key` | various | Experimental | on demand | |
| `debug-bus-graph`, `debug-bus-queues` | GET | Experimental | on demand | eventbus observability (new 2026) |
| `debug-peer-relay-sessions` | GET | Experimental | on demand | peer-relay server sessions (new 2025) |
| `appc-route-info` | GET | Experimental | on demand | app-connector routes |
| `policy/<scope>` (prefix) | GET, POST | Experimental | on demand | syspolicy/MDM effective settings; scope = effective/device/profile/user |
| `disconnect-control` | POST | **Stable** | **implemented (v0.11.0)** | `disconnectControl()` — administrative HA replica drain; wire-shape unit tests only, never exercised against live daemons |
| `debug-capture` | POST (stream) | Unsupported | — | live pcap streaming; out of scope for a monitoring client |
| `dev-set-state-store` | POST | Unsupported | — | dev-only raw state writes |

### Unsupported: the full list and reasons

| Endpoint | Reason |
|----------|--------|
| `dial` | Hijacks the HTTP connection into a raw TCP proxy; no clean mapping onto URLSession or this package's transport abstraction. Use case (userspace `nc`/SSH) is out of scope. |
| `conn25/state` | Brand new (Apr–Jul 2026, renamed mid-flight), explicitly internal, high churn. Revisit when it stabilizes. |
| `alpha-set-device-attrs` | Explicitly alpha per upstream (`tailscale/corp#24690`). |
| `check-so-mark-in-use` | Linux serve preflight internal. |
| `upload-client-metrics` | Tailscale-internal telemetry ingestion. |
| `debug-capture` | Streaming pcap; heavy, niche, better served by upstream tooling. |

---

## Features with no LocalAPI equivalent

### `tailscale netcheck` — client-side STUN

The CLI fetches the DERP map from LocalAPI, then performs its own UDP/STUN probes; results (UDP/IPv4/IPv6 capability, `MappingVariesByDestIP` NAT detection, UPnP/PMP/PCP, per-region latency, preferred DERP, captive portal) are never stored in tailscaled.

**This package's plan (v0.6.0):** native Swift netcheck —
1. `derpMap()` to enumerate regions and STUN endpoints (`HostName` + `STUNPort`, usually 3478)
2. Send STUN Binding Requests over UDP; measure RTT per region
3. Compare mapped addresses across destinations to classify NAT behavior
4. Report a `NetcheckReport` shaped like the CLI's JSON output

### Captive portal detection

Purely CLI-side (`maybe_captiveportal.go`); surfaced by the daemon only as a health warning. Out of scope beyond passing health warnings through.

### Health, netmap, SSH

- **Health**: no dedicated endpoint — read `status.health` or stream `Notify.Health` via the IPN bus.
- **Netmap**: no dedicated endpoint — `debug?action=current-netmap` (debug-gated) or `watch-ipn-bus` with the netmap mask.
- **SSH**: enabling is a prefs edit (`RunSSH`); the CLI's `tailscale ssh` just dials.

---

## IPN Bus reference (`watch-ipn-bus`)

Streaming endpoint; each line is a complete JSON `ipn.Notify`. Fields are omitted unless changed.

| Field | Type | Modeled in Swift (v0.3.1) |
|-------|------|---------------------------|
| `Version`, `SessionID` | string (first message) | ✓ |
| `ErrMessage` | *string | ✓ |
| `State` | *State | ✓ (`IPNState`) |
| `Prefs` | *PrefsView | ✗ — planned v0.4.0 |
| `NetMap` | *NetworkMap | ✗ — planned v0.4.0 |
| `Engine` | *EngineStatus | ✓ (LivePeers dropped) |
| `Health` | *health.State | ✓ |
| `BrowseToURL` | *string | ✓ |
| `LoginFinished` | *empty | ✓ |
| `SuggestedExitNode` | *StableNodeID | ✓ |
| `IncomingFiles` / `OutgoingFiles` / `FilesWaiting` | Taildrop progress | ✗ — planned v0.4.0 |
| `LocalTCPPort` | *uint16 | ✓ |

Watch options (`NotifyWatchOpt`, all 11 bits modeled): engineUpdates, initialState, initialPrefs, initialNetMap, noPrivateKeys, initialDriveShares, initialOutgoingFiles, initialHealthState, rateLimit, healthActions, initialSuggestedExitNode. Until the v0.4.0 model work lands, requesting `initialPrefs`/`initialNetMap` produces payloads the Swift models cannot decode — one reason stream hardening (skip-and-report, not die) ships in the same release.

---

## DERP map reference (`derpmap`)

```json
{
  "Regions": {
    "1": {
      "RegionID": 1,
      "RegionCode": "nyc",
      "RegionName": "New York City",
      "Nodes": [
        {
          "Name": "1a",
          "RegionID": 1,
          "HostName": "derp1.tailscale.com",
          "IPv4": "...",
          "IPv6": "...",
          "STUNPort": 3478,
          "DERPPort": 443
        }
      ]
    }
  }
}
```

Latency probing: for each region take a node's `HostName`/`STUNPort`, send a STUN Binding Request, time the response; the mapped address doubles as NAT-behavior evidence.

---

## References

- [LocalAPI handlers — `ipn/localapi/`](https://github.com/tailscale/tailscale/tree/main/ipn/localapi)
- [Go LocalClient — `client/local/`](https://pkg.go.dev/tailscale.com/client/local)
- [`ipn.Notify`](https://pkg.go.dev/tailscale.com/ipn#Notify) · [`tailcfg.DERPMap`](https://pkg.go.dev/tailscale.com/tailcfg#DERPMap)
- [CLI sources — `cmd/tailscale/cli/`](https://github.com/tailscale/tailscale/tree/main/cmd/tailscale/cli) (the map from CLI subcommands to LocalAPI calls)
