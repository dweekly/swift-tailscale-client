# Changelog

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- macOS LocalAPI discovery using two-tier approach:
  - lsof probe (~140ms) scanning IPNExtension/Tailscale processes
  - Filesystem fallback (~2s) scanning Group Containers
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
  - `TAILSCALE_SKIP_LSOF` - Disable lsof probe
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
