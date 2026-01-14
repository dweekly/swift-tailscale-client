# Roadmap

This roadmap outlines planned development for `swift-tailscale-client`, focusing on endpoints and features that support **network monitoring, diagnostics, and integration** with existing Tailscale installations.

## Philosophy

This package connects to existing `tailscaled` daemons to query their state. It emphasizes read-heavy operations, diagnostics, and network visibility—distinguishing it from [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift), which embeds Tailscale into applications.

**Primary use case:** Network Weather (NWX) macOS app for understanding and diagnosing network connectivity.

---

## v0.3.0 - Streaming & Real-time Updates

**Goal:** Eliminate polling with real-time state change notifications

### Library Features
- [ ] **`/localapi/v0/watch-ipn-bus`** - Stream status changes
  - `AsyncSequence`-based streaming API
  - `Notify` model with State, Health, Engine, NetMap, Prefs fields
  - Watch options bitmask (initial state, rate limiting, etc.)
  - Automatic reconnection handling
- [ ] Models: `Notify`, `EngineStatus`, `NotifyWatchOpt`

### CLI Features
- [ ] `tailscale-swift watch` - Stream live status updates
- [ ] `tailscale-swift watch --json` - JSON output for scripting

### Benefits for NWX
- Instant visibility into connectivity changes
- Health warnings pushed immediately
- No polling overhead

---

## v0.4.0 - Network Infrastructure Visibility

**Goal:** Understand DERP relay infrastructure and optimize routing

### Library Features
- [ ] **`/localapi/v0/derpmap`** - DERP relay server map
  - `DERPMap`, `DERPRegion`, `DERPNode` models
  - Region codes, names, geographic info
  - Node hostnames, IPs, STUN/DERP ports
- [ ] **`/localapi/v0/suggest-exit-node`** - Optimal exit node recommendation
  - Returns best exit node for current network conditions
- [ ] **Native STUN probing** - Pure Swift netcheck equivalent
  - Use DERP map to enumerate STUN endpoints
  - Measure latency to each region
  - Detect NAT type from mapped address variations
  - No shell-out to `tailscale netcheck`

### CLI Features
- [ ] `tailscale-swift derpmap` - Display DERP relay infrastructure
- [ ] `tailscale-swift netcheck` - Network diagnostics (native implementation)
- [ ] `tailscale-swift suggest-exit` - Show recommended exit node

### Benefits for NWX
- DERP latency visualization
- NAT type detection
- Exit node optimization suggestions

---

## v0.5.0 - DNS Diagnostics

**Goal:** DNS debugging and MagicDNS visibility

### Library Features
- [ ] **`/localapi/v0/dns-osconfig`** - OS DNS configuration
  - Nameservers, search domains, match domains
- [ ] **`/localapi/v0/dns-query`** - Perform DNS lookups via Tailscale
  - Test MagicDNS resolution
  - Query types: A, AAAA, CNAME, MX, etc.

### CLI Features
- [ ] `tailscale-swift dns status` - Show DNS configuration
- [ ] `tailscale-swift dns query <name>` - Test DNS resolution

---

## v0.6.0 - Configuration Management

**Goal:** Enable preference modification and exit node control

### Library Features
- [ ] **`/localapi/v0/prefs` (PATCH)** - Modify preferences
  - Exit node selection
  - Shields up/down
  - Accept routes toggle
- [ ] **`/localapi/v0/set-use-exit-node-enabled`** - Toggle exit node

### CLI Features
- [ ] `tailscale-swift set exit-node <node>` - Switch exit node
- [ ] `tailscale-swift set shields-up` - Enable/disable shields

---

## Future Considerations (Post-1.0)

These features are deferred pending community demand:

### Taildrop (File Transfer)
- `/localapi/v0/files` - List received files
- `/localapi/v0/file-targets` - List receivers
- `/localapi/v0/file-get/:filename` - Download files
- `/localapi/v0/file-put/:node/:filename` - Send files

### Authentication & Session Management
- `/localapi/v0/login-interactive` - Interactive login
- `/localapi/v0/logout` - Logout current node
- `/localapi/v0/profiles/` - Profile management

### Debug & Diagnostics
- `/localapi/v0/bugreport` - Generate diagnostic bundles
- `/localapi/v0/logtap` - Stream daemon logs
- `/localapi/v0/goroutines` - Goroutine stack traces

### Certificate Management
- `/localapi/v0/cert` - TLS certificate retrieval

### Sample Applications
- Full-featured macOS menu bar app
- iOS/macOS widget showing connection status
- SwiftUI dashboard with real-time updates

---

## Non-Goals

To maintain focus and avoid scope creep:

- **Embedded Tailscale:** Creating new tailnet nodes belongs in [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift)
- **CLI Replacement:** Not competing with official `tailscale` CLI
- **Shelling Out:** All functionality implemented in pure Swift
- **Linux-First:** Prioritizing macOS/iOS, but keeping Linux-compatible where practical
- **Backwards Compatibility:** Pre-1.0 APIs may change; 1.0+ will follow SemVer strictly

---

## Implementation Notes

See [`docs/LOCALAPI-COVERAGE.md`](docs/LOCALAPI-COVERAGE.md) for detailed analysis of:
- All available LocalAPI endpoints
- CLI-only features and how to replicate them
- IPN bus message structure
- DERP map format and STUN probing strategy

---

## Contributing to the Roadmap

Have ideas or need specific endpoints? Please open an issue on GitHub to discuss:
- Use case description
- Endpoint requirements
- Expected models/responses

Community input shapes priority order.
