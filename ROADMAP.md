# Roadmap

This roadmap outlines planned development for `swift-tailscale-client`, focusing on endpoints and features that support **monitoring, tooling, and integration** with existing Tailscale installations.

## Philosophy

This package connects to existing `tailscaled` daemons to query their state. It emphasizes read-heavy operations, diagnostics, and configuration inspection—distinguishing it from [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift), which embeds Tailscale into applications.

---

## v0.1.0 - Status API ✅ (Released)

**Goal:** Rock-solid foundation with comprehensive `/localapi/v0/status` support

### Completed Features
- ✅ Full `/localapi/v0/status` endpoint implementation
- ✅ Comprehensive Swift models for all status response fields
- ✅ Transport abstraction (Unix socket + TCP loopback)
- ✅ macOS LocalAPI discovery (lsof probe + filesystem fallback)
- ✅ Environment variable overrides for all configuration
- ✅ Strict Swift 6 concurrency with full Sendable conformance
- ✅ Comprehensive test suite (unit + integration tests)
- ✅ CI/CD with GitHub Actions
- ✅ DocC documentation site deployed to GitHub Pages
- ✅ Development CLI tool (`tailscale-swift status`)
- ✅ Man pages and inline help

---

## v0.1.1 - Polish & Fixes 🚧 (Current)

**Goal:** Address post-release issues and improve documentation

- [ ] Fix CI swiftlint issues (or remove swiftlint in favor of swift format)
- [ ] Update CHANGELOG with complete v0.1.0 feature list
- [ ] Add DocC documentation badge to README
- [ ] Bug fixes based on community feedback
- [ ] Improve error messages with contextual information

**Timeline:** 1 week

---

## v0.2.0 - Essential Monitoring

**Goal:** Add critical endpoints for monitoring and tooling use cases

### Library Features
- [ ] **`/localapi/v0/whois`** - Identity lookup by IP or node key
  - `WhoIsResponse`, `WhoIsNode`, `WhoIsUserProfile` models
  - Essential for "who is this peer?" queries
- [ ] **`/localapi/v0/prefs` (GET)** - Read current preferences
  - `Prefs` model with all configuration settings
  - Enable config inspection without modifying state
- [ ] **`/localapi/v0/ping`** - Network connectivity diagnostics
  - `PingRequest`, `PingResponse` models
  - POST endpoint for testing peer-to-peer connectivity

### CLI Features
- [ ] `tailscale-swift whois <ip-or-node>` - Lookup identity
- [ ] `tailscale-swift ping <ip>` - Test connectivity
- [ ] `tailscale-swift prefs` - Display current preferences

### Testing & Documentation
- [ ] JSON fixtures for all new endpoints
- [ ] Integration tests with real daemon
- [ ] DocC tutorials for whois/ping/prefs
- [ ] Update README with examples

**Timeline:** 2-3 weeks

---

## v0.3.0 - Taildrop Support

**Goal:** File transfer monitoring and basic Taildrop operations

### Library Features
- [ ] **`/localapi/v0/files`** - List received Taildrop files
- [ ] **`/localapi/v0/file-targets`** - List available Taildrop receivers
- [ ] **`/localapi/v0/file-get/:filename`** - Download received files
- [ ] **`/localapi/v0/file-put/:node/:filename`** - Send files
- [ ] Models: `TaildropFile`, `FileTarget`, progress tracking

### CLI Features
- [ ] `tailscale-swift files list` - Show received files
- [ ] `tailscale-swift files send <target> <file>` - Send file
- [ ] `tailscale-swift files get <filename>` - Download file
- [ ] `tailscale-swift targets` - List Taildrop-enabled peers

### Sample Application
- [ ] Simple SwiftUI menu bar app showing status + Taildrop
- [ ] Demonstrates package integration patterns

**Timeline:** 2-3 weeks

---

## v0.4.0 - Streaming & Advanced Diagnostics

**Goal:** Real-time updates and deep system insights

### Library Features
- [ ] **`/localapi/v0/watch-ipn-bus`** - Stream status changes
  - AsyncSequence-based streaming API
  - Models for IPN bus messages (`Notify`, `BrowseToURL`, etc.)
  - Automatic reconnection handling
- [ ] **`/localapi/v0/metrics`** - Internal performance metrics
- [ ] **`/localapi/v0/health`** - System health checks
  - Warnings, errors, configuration issues
- [ ] Enhanced error handling with request tracing

### CLI Features
- [ ] `tailscale-swift watch` - Stream live status updates
- [ ] `tailscale-swift health` - Display health warnings
- [ ] `tailscale-swift metrics` - Show performance metrics

**Timeline:** 3-4 weeks

---

## v0.5.0 - Configuration Management

**Goal:** Enable preference modification and advanced configuration

### Library Features
- [ ] **`/localapi/v0/prefs` (PATCH)** - Modify preferences
  - Exit node selection
  - Shields up/down
  - Route advertisement
  - DNS settings
  - Proper diff/patch logic to avoid race conditions
- [ ] **`/localapi/v0/routes`** - Subnet routes information
- [ ] **`/localapi/v0/advertise-routes`** - Manage custom routes

### CLI Features
- [ ] `tailscale-swift set exit-node <node>` - Switch exit node
- [ ] `tailscale-swift set shields-up` - Enable/disable shields
- [ ] `tailscale-swift routes` - Display routing configuration
- [ ] `tailscale-swift advertise-routes <cidr>` - Advertise subnet

**Timeline:** 2-3 weeks

---

## Future Considerations (Post-1.0)

These features are deferred pending community demand:

### Authentication & Session Management
- `/localapi/v0/login-interactive` - Interactive login
- `/localapi/v0/logout` - Logout current node
- Profile management endpoints

### Debug & Diagnostics
- `/localapi/v0/bugreport` - Generate diagnostic bundles
- `/localapi/v0/goroutines` - Goroutine stack traces
- `/localapi/v0/component-debug-logging` - Verbose logging control

### Certificate Management
- `/localapi/v0/cert` - TLS certificate retrieval
- `/localapi/v0/cert/<domain>` - Domain-specific certificates

### Advanced Features
- Update checking (`/localapi/v0/update/check`)
- Network lock (Tailnet key authority) endpoints
- Serve/Funnel configuration endpoints

### Sample Applications
- Full-featured macOS menu bar app
- iOS/macOS widget showing connection status
- SwiftUI dashboard with real-time updates

---

## Non-Goals

To maintain focus and avoid scope creep:

- **Embedded Tailscale:** Creating new tailnet nodes belongs in [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift)
- **CLI Replacement:** Not competing with official `tailscale` CLI
- **Linux-First:** Prioritizing macOS/iOS, but keeping Linux-compatible where practical
- **Backwards Compatibility:** Pre-1.0 APIs may change; 1.0+ will follow SemVer strictly

---

## Contributing to the Roadmap

Have ideas or need specific endpoints? Please open an issue on GitHub to discuss:
- Use case description
- Endpoint requirements
- Expected models/responses

Community input shapes priority order beyond v0.2.0.
