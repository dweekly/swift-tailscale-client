# LocalAPI Coverage

Complete inventory of the Tailscale LocalAPI surface and this package's position on every endpoint: implemented, planned (with target version), experimental, or deliberately unsupported (with the reason).

**Last updated:** 2026-08-02
**Upstream reference:** `tailscale/tailscale` `main` (July 2026), `ipn/localapi/` + `client/local/`
**swift-tailscale-client version:** 0.9.0

Tiers are defined in [`ROADMAP.md`](../ROADMAP.md#stability--support-tiers): **Stable** (methods on `TailscaleClient`, SemVer-protected post-1.0), **Experimental** (`client.experimental`, exempt from SemVer), **Unsupported** (documented, not wrapped).

---

## How the LocalAPI is put together (read this first)

Three upstream facts shape everything below:

1. **Endpoint availability is build-dependent.** Since the daemon was modularized, only ~21 handlers are always registered; the rest are attached at `init()` time by optional `feature/*` packages and build-tag-gated code. A size-trimmed tailscaled returns 404 for endpoints this table lists. `POST /localapi/v0/debug-optional-features` reports which optional features a daemon was compiled with — this package's capability-probing strategy (planned `daemonFeatures()`, v0.4.0) is built on it.
2. **Routing is exact-match with one level of prefix fallback.** The suffix after `/localapi/v0/` is looked up exactly; on a miss it is truncated at the first `/` and looked up again. Only `cert/`, `files/`, `file-put/`, `profiles/`, and `policy/` are true prefixes. Keys like `tka/status` and `update/check` are exact entries that happen to contain a slash.
3. **The `Host` header must be empty or `local-tailscaled.sock`.** A loopback/`localhost` Host is only accepted when the daemon requires basic auth (the Windows/token path). Upstream also warns that LocalAPI paths are "not necessarily stable APIs" — hence the tier system.

---

## Summary

| Category | Count |
|----------|-------|
| Implemented | 31 (+ 6 experimental) |
| Planned Stable (v0.4.0–v1.3) | ~40 |
| Planned Experimental | ~15 |
| Unsupported (documented, with reasons) | 7 |
| No LocalAPI equivalent (client-side features) | netcheck (implemented client-side in v0.6.0 as `Netcheck`), captive portal detection |

---

## Implemented

| Endpoint | Method | Swift API | Notes |
|----------|--------|-----------|-------|
| `status` | GET | `status(query:)` | `?peers=false` supported via `StatusQuery` |
| `whois` | GET | `whois(address:)` | `?addr=`; `?proto=` not yet exposed |
| `prefs` | GET, PATCH | `prefs()`, `editPrefs(_:)` | PATCH since v0.8.0 via typed `MaskedPrefs` |
| `ping` | POST | `ping(ip:type:size:)` | disco/TSMP/ICMP/peerAPI |
| `metrics` | GET | `metrics()` | Prometheus text; feature-gated upstream (`HasClientMetrics`/`HasDebug`) |
| `watch-ipn-bus` | GET (streaming) | `watchIPNBus(options:reconnect:onUndecodableLine:)` | `AsyncThrowingStream<IPNNotify, Error>`; skip-and-report + opt-in reconnect since v0.4.0 |
| `debug-optional-features` | POST | `daemonFeatures()` | v0.4.0 — the capability-probing foundation |
| `derpmap` | GET | `derpMap()` | v0.6.0 — typed `DERPMap`/`DERPRegion`/`DERPNode` |
| `suggest-exit-node` | GET, POST | `suggestExitNode(forceProbe:)` | v0.6.0 — GET by default (works on older daemons); `forceProbe: true` POSTs `?probe=true` (1.86+) |
| `usermetrics` | GET | `userMetrics()` | v0.6.0 — stable Prometheus user metrics; 404/501 → `endpointUnavailable` |
| `dns-osconfig` | GET | `dnsOSConfig()` | v0.7.0 — nameservers, search + split-DNS match domains |
| `dns-query` | GET | `dnsQuery(name:type:)` | v0.7.0 — raw RFC 1035 answer + chosen resolvers |
| `check-ip-forwarding` | GET | `checkIPForwarding()` | v0.7.0 — subnet-router/exit-node preflight |
| `dns-config` | GET | `dnsConfig()` | netmap DNS intent (vs installed `dns-osconfig`) |
| `peer-by-id` | GET | `peer(byID:)` | v0.7.0 — full `tailcfg.Node` via `WhoIsNode`; 404 = not in netmap |
| `user-profile` | GET | `userProfile(byID:)` | v0.7.0 — resolves numeric `UserID` references |
| `bugreport` / `goroutines` / `logtap` | POST / GET / stream | `experimental.*` | v0.7.0 — SemVer-exempt debug tier |
| `check-prefs` | POST | `checkPrefs(_:)` | v0.8.0 — validate without applying |
| `set-use-exit-node-enabled` | POST | `setUseExitNode(enabled:)` | v0.8.0 — toggle without forgetting the selection |
| `set-expiry-sooner` | POST | `setExpirySooner(_:)` | v0.8.0 — key hygiene |
| `reload-config` | POST | `reloadConfig()` | v0.8.0 — config-file daemons |
| `start` | POST | `start(options:)` | v0.8.0 — backend start / headless auth-key bring-up |
| `login-interactive` / `logout` / `reset-auth` | POST | `loginInteractive()`, `logout()`, `resetAuth()` | v0.9.0 — BrowseToURL via IPN bus; destructive pair unit-tested only |
| `profiles/` | GET/PUT/POST/DELETE | `profiles()`, `currentProfile()`, `addProfile()`, `switchProfile(_:)`, `deleteProfile(_:)` | v0.9.0 — `LoginProfile` model |
| `id-token` | POST | `idToken(audience:)` | v0.9.0 — OIDC token, raw JSON passthrough |
| `set-gui-visible` / `set-push-device-token` / `handle-push-message` | POST | `experimental.setGUIVisible(_:sessionID:)`, `.setPushDeviceToken(_:)`, `.handlePushMessage(_:)` | v0.9.0 — GUI-client contract, SemVer-exempt |
| `serve-config` | GET, POST | `serveConfig()`, `setServeConfig(_:)` | v0.10.0 — ETag optimistic concurrency; stale writes throw `.preconditionFailed` |
| `cert-domains` | GET | `certDomains()` | v0.10.0 |
| `cert/<domain>` | GET | `certPEM(domain:kind:minValidity:)`, `certPair(domain:minValidity:)` | v0.10.0 — first fetch may block on ACME issuance |
| `set-dns` | POST | `setDNS(name:value:)` | v0.10.0 — ACME DNS-01 TXT; control-plane rate-limited |
| `query-feature` | POST | `queryFeature(_:)` | v0.10.0 — control-plane feature probe (serve/funnel) |

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
| `profiles/` (prefix) | GET, PUT, POST, DELETE | core | Stable | **v0.9.0** | `profiles()`, `currentProfile()`, `addProfile()`, `switchProfile(_:)`, `deleteProfile(_:)` |
| `shutdown` | POST | core | Stable | v1.0.0 | `shutdownDaemon()` |

### Serve, Funnel & certificates

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `serve-config` | GET, POST | `HasServe` | Stable | **v0.10.0** | `serveConfig()` → snapshot with `etag`; `setServeConfig(_:)` sends `If-Match` — a stale write throws `.preconditionFailed(body:endpoint:)` (proven against a live daemon in the write lane) |
| `cert-domains` | GET | `HasACME` | Stable | **v0.10.0** | `certDomains()` |
| `cert/<domain>` (prefix) | GET | `HasACME` | Stable | **v0.10.0** | `certPEM(domain:kind:minValidity:)` (`?type=pair\|cert\|key`), `certPair(domain:minValidity:)` splits key/cert |
| `set-dns` | POST | `HasACME` | Stable | **v0.10.0** | `setDNS(name:value:)` — ACME DNS-01 TXT |
| `query-feature` | POST | `HasServe` | Stable | **v0.10.0** | `queryFeature(_:)` — `QueryFeatureResponse` |
| `check-so-mark-in-use` | GET | core | Unsupported | — | Linux `tailscale serve` preflight internal; no Swift use case |

### Taildrop & Taildrive (post-1.0)

| Endpoint | Method(s) | Gating | Tier | Status | Swift API |
|----------|-----------|--------|------|--------|-----------|
| `file-put/<target>/<name>` (prefix) | PUT, POST | taildrop feature | Stable | v1.1 | `pushFile(...)` |
| `files/` (prefix) | GET, DELETE | taildrop feature | Stable | v1.1 | `waitingFiles()`, `awaitWaitingFiles()` (`?waitfor=` long-poll), `getWaitingFile(_:)`, `deleteWaitingFile(_:)` |
| `file-targets` | GET | taildrop feature | Stable | v1.1 | `fileTargets()` |
| `drive/fileserver-address` | PUT | drive feature | Stable | v1.2 | `setDriveFileServerAddress(_:)` |
| `drive/shares` | GET, PUT, POST, DELETE | drive feature | Stable | v1.2 | `driveShares()`, set/rename/remove |

### Tailnet Lock (post-1.0)

All 13 endpoints, wrapped under **`TailnetLock`** naming (upstream renamed from `NetworkLock`; the Go `NetworkLock*` methods are deprecated aliases). Note `tka/modify` returns **204 No Content**.

| Endpoint | Method | Tier | Status |
|----------|--------|------|--------|
| `tka/status`, `tka/log` (`?limit=`) | GET | Stable | v1.3 |
| `tka/init`, `tka/modify`, `tka/sign`, `tka/disable`, `tka/force-local-disable`, `tka/affected-sigs`, `tka/wrap-preauth-key`, `tka/verify-deeplink`, `tka/generate-recovery-aum`, `tka/cosign-recovery-aum`, `tka/submit-recovery-aum` | POST | Stable | v1.3 |

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
| `update/check` | GET | `HasClientUpdate` | Experimental | on demand |
| `update/install` | POST | `HasClientUpdate` | Experimental | on demand |
| `update/progress` | GET | `HasClientUpdate` | Experimental | on demand — often overlooked; needed to display install progress |

Note: the official CLI's `tailscale update` does *not* use these — it runs the updater in-process. These exist for GUI clients.

### Debug & introspection

| Endpoint | Method(s) | Tier | Status | Notes |
|----------|-----------|------|--------|-------|
| `debug-optional-features` | POST | **Stable** | **implemented (v0.4.0)** | `daemonFeatures()`; the capability-discovery endpoint this package's probing strategy is built on |
| `bugreport` | POST | Experimental | **v0.7.0** | `experimental.bugreport(note:diagnose:record:)` |
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
| `disconnect-control` | POST | Unsupported | — | drops the control-plane connection; test-harness tool |
| `debug-capture` | POST (stream) | Unsupported | — | live pcap streaming; out of scope for a monitoring client |
| `dev-set-state-store` | POST | Unsupported | — | dev-only raw state writes |

### Unsupported: the full list and reasons

| Endpoint | Reason |
|----------|--------|
| `dial` | Hijacks the HTTP connection into a raw TCP proxy; no clean mapping onto URLSession or this package's transport abstraction. Use case (userspace `nc`/SSH) is out of scope. |
| `conn25/state` | Brand new (Apr–Jul 2026, renamed mid-flight), explicitly internal, high churn. Revisit when it stabilizes. |
| `alpha-set-device-attrs` | Explicitly alpha per upstream (`tailscale/corp#24690`). |
| `disconnect-control` | Daemon test harness tool. |
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
