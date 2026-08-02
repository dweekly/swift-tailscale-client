# Changelog

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
