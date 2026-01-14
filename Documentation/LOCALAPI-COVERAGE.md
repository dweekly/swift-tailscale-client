# LocalAPI Coverage Analysis

This document tracks the Tailscale LocalAPI endpoints, what's implemented in swift-tailscale-client, and what's available only via the CLI.

**Last updated:** 2025-01-14
**Tailscale version tested:** 1.92.3
**swift-tailscale-client version:** 0.2.1

---

## Summary

| Category | Count |
|----------|-------|
| Implemented in swift-tailscale-client | 5 |
| Available via LocalAPI (not yet implemented) | ~25 |
| CLI-only (no LocalAPI equivalent) | 3 |

---

## Currently Implemented in swift-tailscale-client

| Endpoint | Method | Swift API | Description |
|----------|--------|-----------|-------------|
| `/localapi/v0/status` | GET | `status(query:)` | Node status, peers, exit node, health warnings |
| `/localapi/v0/whois` | GET | `whois(address:)` | Identity lookup by Tailscale IP |
| `/localapi/v0/prefs` | GET | `prefs()` | Current node preferences |
| `/localapi/v0/ping` | POST | `ping(ip:type:size:)` | Connectivity test with latency |
| `/localapi/v0/metrics` | GET | `metrics()` | Prometheus-format internal metrics |

### Additional Features (not direct endpoints)
| Feature | Implementation | Description |
|---------|---------------|-------------|
| Network interface discovery | `NetworkInterfaceDiscovery` | Finds TUN interface via `getifaddrs` |
| macOS LocalAPI discovery | `MacClientInfo` | Finds App Store GUI's loopback API via libproc |

---

## Available via LocalAPI (Not Yet Implemented)

### High Priority for Network Diagnostics

| Endpoint | Method | Description | Value for NWX |
|----------|--------|-------------|---------------|
| `/localapi/v0/watch-ipn-bus` | GET (streaming) | Stream real-time state changes | Eliminates polling; instant updates for Health, NetMap, Engine stats |
| `/localapi/v0/derpmap` | GET | DERP relay server map | Shows relay infrastructure; foundation for latency probing |
| `/localapi/v0/suggest-exit-node` | POST | Recommend optimal exit node | Help users optimize routing |
| `/localapi/v0/dns-osconfig` | GET | OS DNS configuration | DNS debugging |
| `/localapi/v0/dns-query` | POST | Perform DNS lookup via Tailscale | Test MagicDNS resolution |
| `/localapi/v0/usermetrics` | GET | User-facing metrics (distinct from /metrics) | Cleaner metrics for display |

### Medium Priority

| Endpoint | Method | Description | Notes |
|----------|--------|-------------|-------|
| `/localapi/v0/check-ip-forwarding` | GET | Validate IP forwarding | Useful for subnet router diagnostics |
| `/localapi/v0/logtap` | GET (streaming) | Stream daemon logs | Debug logging |
| `/localapi/v0/bugreport` | POST | Generate diagnostic bundle | Support/debugging |
| `/localapi/v0/goroutines` | GET | Goroutine stack traces | Deep debugging |
| `/localapi/v0/profiles/` | GET/POST/DELETE | Manage user profiles | Multi-account support |

### Lower Priority / Specialized

| Endpoint | Method | Description | Notes |
|----------|--------|-------------|-------|
| `/localapi/v0/prefs` | PATCH | Modify preferences | Write operations (exit node, shields, routes) |
| `/localapi/v0/login-interactive` | POST | Interactive login flow | Auth management |
| `/localapi/v0/logout` | POST | Logout current node | Auth management |
| `/localapi/v0/start` | POST | Start backend service | Lifecycle management |
| `/localapi/v0/shutdown` | POST | Shutdown daemon | Lifecycle management |
| `/localapi/v0/reset-auth` | POST | Reset auth state | Auth management |
| `/localapi/v0/set-expiry-sooner` | POST | Shorten key expiry | Key management |
| `/localapi/v0/reload-config` | POST | Reload config from disk | Config management |
| `/localapi/v0/check-prefs` | POST | Validate prefs before applying | Config validation |
| `/localapi/v0/dial` | POST | Establish proxy connection | SSH/proxy support |
| `/localapi/v0/cert` | GET | TLS certificate retrieval | HTTPS cert management |
| `/localapi/v0/set-dns` | POST | Configure DNS settings | DNS management |
| `/localapi/v0/set-use-exit-node-enabled` | POST | Toggle exit node | Exit node control |
| `/localapi/v0/id-token` | GET | OIDC identity token | Auth tokens |
| `/localapi/v0/query-feature` | GET | Query feature availability | Feature detection |

### Capability-Gated Endpoints

Some endpoints require specific capabilities advertised to the LocalAPI:

| Endpoint | Required Capability | Description |
|----------|-------------------|-------------|
| `/localapi/v0/watch-ipn-bus` | `HasDebug` or `HasServe` | IPN bus streaming |
| `/localapi/v0/metrics` | `HasClientMetrics` or `HasDebug` | Prometheus metrics |
| `/localapi/v0/suggest-exit-node` | `HasUseExitNode` | Exit node suggestions |
| `/localapi/v0/bugreport` | `HasDebug` | Bug reports |
| `/localapi/v0/logtap` | `HasLogTail` | Log streaming |
| `/localapi/v0/usermetrics` | `HasUserMetrics` | User metrics |

---

## CLI-Only Features (No LocalAPI Equivalent)

These features are computed client-side by the `tailscale` CLI and are **not available via LocalAPI**:

### `tailscale netcheck`

**What it provides:**
```json
{
  "UDP": true,
  "IPv4": true,
  "IPv6": false,
  "MappingVariesByDestIP": false,
  "UPnP": false,
  "PMP": false,
  "PCP": false,
  "PreferredDERP": 2,
  "RegionLatency": {
    "sfo": 12500000,
    "lax": 19200000,
    "sea": 26100000
  },
  "CaptivePortal": null
}
```

**Why it's CLI-only:** The CLI performs its own UDP/STUN probes to DERP servers. This data is not stored in tailscaled.

**How to replicate without shelling out:**
1. Fetch `/localapi/v0/derpmap` to get DERP server list
2. Implement STUN client in Swift (send binding requests to each DERP's STUN port)
3. Measure RTT for each probe
4. Detect NAT type by comparing mapped addresses across destinations

### `tailscale dns status --all`

**What it provides:**
- MagicDNS configuration
- Resolvers and fallback resolvers
- Split DNS routes
- Search domains
- System DNS configuration

**LocalAPI partial equivalent:** `/localapi/v0/dns-osconfig` provides OS DNS config, but not the full formatted output.

### `tailscale exit-node suggest`

**What it provides:** Best exit node recommendation based on current network conditions.

**LocalAPI equivalent:** `/localapi/v0/suggest-exit-node` - **this IS available via LocalAPI** (listed above).

---

## IPN Bus Streaming (`/localapi/v0/watch-ipn-bus`)

This is a streaming endpoint that sends `ipn.Notify` messages as JSON lines.

### Notify Fields

| Field | Type | Description |
|-------|------|-------------|
| `Version` | string | Backend version (first message only) |
| `SessionID` | string | Unique session ID (first message only) |
| `ErrMessage` | *string | Critical error message |
| `State` | *State | Backend state change (Running, Stopped, NeedsLogin, etc.) |
| `Prefs` | *PrefsView | Preferences changed |
| `NetMap` | *NetworkMap | Network topology changed |
| `Engine` | *EngineStatus | WireGuard stats (RxBytes, TxBytes, NumLive) |
| `Health` | *health.State | Health warnings changed |
| `BrowseToURL` | *string | URL to open (OAuth flow) |
| `LoginFinished` | *empty | Login completed |
| `SuggestedExitNode` | *StableNodeID | Best exit node changed |
| `IncomingFiles` | []PartialFile | Taildrop files being received |
| `OutgoingFiles` | []*OutgoingFile | Taildrop files being sent |

### Watch Options (bitmask)

| Option | Description |
|--------|-------------|
| `NotifyWatchEngineUpdates` | Include periodic Engine stats |
| `NotifyInitialState` | First message includes current State |
| `NotifyInitialPrefs` | First message includes current Prefs |
| `NotifyInitialNetMap` | First message includes current NetMap |
| `NotifyInitialHealthState` | First message includes Health |
| `NotifyInitialSuggestedExitNode` | First message includes SuggestedExitNode |
| `NotifyRateLimit` | Rate-limit spammy netmap updates |

### Implementation Notes

- Streaming HTTP response (chunked transfer or SSE-like)
- Each line is a complete JSON object
- Most fields are nil/omitted unless changed
- Need `AsyncSequence` wrapper for Swift consumption

---

## DERP Map Structure (`/localapi/v0/derpmap`)

The DERP map contains relay server information:

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

### Using DERP Map for Latency Probing

To replicate `netcheck` DERP latencies:
1. For each region, get the first node's `HostName` and `STUNPort` (usually 3478)
2. Send STUN Binding Request (UDP)
3. Measure time until Binding Response
4. The mapped address in the response also reveals NAT behavior

---

## Data Available in Status vs Netcheck

| Data Point | `/status` | `netcheck` | Notes |
|------------|-----------|------------|-------|
| Peer list | ✓ | ✗ | |
| Peer online/offline | ✓ | ✗ | |
| Peer connection type (direct/DERP) | ✓ | ✗ | Via `CurAddr` field |
| Peer traffic stats | ✓ | ✗ | RxBytes, TxBytes |
| Last handshake | ✓ | ✗ | |
| Health warnings | ✓ | ✗ | |
| Self DERP home | ✓ | ✗ | `Relay` field |
| UDP connectivity | ✗ | ✓ | |
| IPv4/IPv6 capability | ✗ | ✓ | |
| NAT type | ✗ | ✓ | MappingVariesByDestIP |
| Port mapping (UPnP/PMP/PCP) | ✗ | ✓ | |
| DERP latencies (all regions) | ✗ | ✓ | |
| Captive portal detection | ✗ | ✓ | |
| Preferred DERP | ✗ | ✓ | |

---

## Recommended Implementation Order for NWX

### Phase 1: Real-time Updates
1. **`/localapi/v0/watch-ipn-bus`** - Streaming state changes
   - Eliminates polling
   - Instant visibility into connectivity changes
   - Health warnings pushed immediately

### Phase 2: Network Infrastructure Visibility
2. **`/localapi/v0/derpmap`** - DERP relay map
   - Foundation for understanding relay infrastructure
   - Required for Phase 3

3. **`/localapi/v0/suggest-exit-node`** - Exit node optimization
   - Quick win, simple endpoint

### Phase 3: Native Network Probing (replaces netcheck)
4. **STUN client implementation** - Pure Swift
   - Use DERP map to get server list
   - Probe each region's STUN port
   - Measure latencies
   - Detect NAT type from mapped addresses

### Phase 4: DNS Diagnostics
5. **`/localapi/v0/dns-osconfig`** - OS DNS configuration
6. **`/localapi/v0/dns-query`** - DNS lookup testing

---

## References

- [LocalAPI source (localapi.go)](https://github.com/tailscale/tailscale/blob/main/ipn/localapi/localapi.go)
- [IPN Notify struct](https://pkg.go.dev/tailscale.com/ipn#Notify)
- [Go client documentation](https://pkg.go.dev/tailscale.com/client/local)
- [DERP map types](https://pkg.go.dev/tailscale.com/tailcfg#DERPMap)
