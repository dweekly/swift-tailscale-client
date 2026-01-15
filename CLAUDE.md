# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial, MIT-licensed Swift 6 package providing async/await access to the Tailscale LocalAPI for Apple platforms. It's designed for building monitoring tools, status widgets, dashboards, and developer utilities that work with an existing Tailscale installation.

**Important**: This is NOT an official Tailscale product and has no affiliation with Tailscale Inc. Maintain this disclaimer in README, DocC, and source headers. This is NOT an embedded Tailscale implementation—use official [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift) for that.

## Build and Test Commands

```bash
# Build the package
swift build

# Format code
swift format --in-place --recursive Sources/ Tests/

# Lint code (CI uses swift format lint only)
swift format lint --recursive Sources/ Tests/

# Run all tests (unit tests with mocked transport only)
swift test

# Run integration tests (requires local tailscaled instance)
TAILSCALE_INTEGRATION=1 swift test --filter TailscaleClientIntegrationTests

# Run a single test
swift test --filter StatusAPITests

# Build documentation
swift package --allow-writing-to-directory ./docs \
    generate-documentation --target TailscaleClient \
    --output-path ./docs

# Enable LocalAPI discovery debug logging
TAILSCALE_DISCOVERY_DEBUG=1 swift test

# Run the development CLI tool
swift run tailscale-swift status
```

## Architecture

### Layered Design

1. **Transport Layer** (`Transport/`)
   - `TailscaleTransport` protocol: Pluggable transport abstraction
   - `URLSessionTailscaleTransport`: Production implementation supporting both Unix domain sockets and loopback TCP
   - `UnixSocketTransport`: Low-level Unix socket communication using `CFSocket` and `connect(2)`
   - Handles header injection (`Tailscale-Cap`, `Authorization`), request building, and network error mapping

2. **Configuration & Discovery** (`Configuration/`)
   - `TailscaleClientConfiguration`: Connection settings (endpoint, auth token, capability version, transport)
   - `LocalAPIDiscovery`: Environment variable and platform-specific discovery of LocalAPI endpoint
   - `.default` configuration auto-discovers via env vars, then platform-specific methods, then fallback socket paths
   - On macOS, uses `MacClientInfo` to locate App Store GUI's loopback API

3. **macOS Platform Discovery** (`Platform/MacClientInfo.swift`)
   - **IMPORTANT**: App Store discovery is disabled by default to avoid TCC popups
   - Must explicitly opt-in: `TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)`
   - Discovery order (when socket discovery fails and App Store discovery is enabled):
     1. **libproc** (PRIMARY): Uses `proc_pidinfo` to find IPNExtension's open files (~5ms)
     2. **Filesystem fallback**: Enumerates Group Containers directories (~50-200ms)
   - Respects `TAILSCALE_SAMEUSER_PATH`, `TAILSCALE_SAMEUSER_DIR`, `TAILSCALE_SKIP_LIBPROC`
   - Use `TAILSCALE_DISCOVERY_DEBUG=1` for verbose logging to stderr

4. **Models** (`Models/`)
   - `StatusResponse`: Strongly-typed Codable models mirroring LocalAPI JSON responses
   - `StatusQuery`: Query parameters for status endpoint (e.g., `includePeers`)
   - All models are `Sendable` for Swift 6 strict concurrency

5. **Client API** (`TailscaleClient.swift`)
   - Public `actor TailscaleClient` providing thread-safe async access
   - Exposes: `status(query:)`, `whois(address:)`, `prefs()`, `ping(ip:type:size:)`, `metrics()`
   - Maps transport errors to `TailscaleClientError` (`.transport`, `.unexpectedStatus`, `.decoding`)

6. **Network Interface Discovery** (`Platform/NetworkInterfaceDiscovery.swift`)
   - Uses BSD `getifaddrs` to enumerate system interfaces
   - Matches Tailscale IPs to find the TUN interface (e.g., `utun16`)
   - Exposed via `StatusResponse.interfaceName` and `StatusResponse.interfaceInfo`

### Key Patterns

- **Swift 6 Strict Concurrency**: All public types are `Sendable`; use `actor` for state isolation
- **Async/await throughout**: No callbacks or completion handlers
- **Protocol-oriented transport**: Inject `MockTransport` in tests, use real transports in production
- **Graceful discovery fallback**: LocalAPI discovery degrades gracefully through multiple strategies
- **Unix socket support**: Custom CFSocket-based implementation for Unix domain socket communication

## Testing Strategy

- **Unit tests**: Use `MockTransport` with fixture JSON files from `Tests/TailscaleClientTests/Fixtures/`
- **Integration tests**: Gated behind `TAILSCALE_INTEGRATION=1` environment variable; talk to real tailscaled
- **XCTest patterns**: Use `XCTAssertThrowsErrorAsync` helper (defined in `TestSupport.swift`) for async error assertions
- **Request recording**: Use `RequestRecorder` actor pattern (see `StatusAPITests.swift`) to verify requests in tests
- **CI is hermetic**: GitHub Actions runs only mock-backed unit tests; no real tailscaled dependency

## Development Guidelines

- **Never manually edit Xcode project files**: Have the human user perform XCode modifications
- **Swift 6 features required**: Use async/await and actors throughout; avoid legacy concurrency patterns
- **Platform-specific code**: Use `#if os(macOS)` for macOS-specific discovery logic
- **Error handling**: Provide detailed error context (transport errors include underlying errors, decoding errors include body)
- **Documentation**: Add DocC doc comments to all public APIs; include usage examples
- **Environment variable overrides**: Support them for all configuration (see README table); useful for testing and CI
- **Directory structure**:
  - `Documentation/` - Project documentation (markdown files, analysis docs, man pages). **Committed to git.**
  - `docs/` - Generated DocC output. **Gitignored.** Never put project docs here.

## Project Status (v0.3.0)

**Current version**: v0.3.0 - IPN Bus Streaming

**Primary use case**: Network Weather (NWX) macOS app for network diagnostics.

**Recent releases**:
- v0.3.0: IPN bus streaming (`watchIPNBus()`) for real-time state updates
- v0.2.1: Network interface discovery (`StatusResponse.interfaceName`, `StatusResponse.interfaceInfo`)
- v0.2.0: Added `whois()`, `prefs()`, `ping()`, `metrics()` endpoints; pure Swift libproc-based discovery

**CLI commands available**: `status`, `whois`, `prefs`, `ping`, `health`, `metrics`, `watch`

**Roadmap** (see `ROADMAP.md`):
- v0.4.0: DERP map, exit node suggestions, native STUN probing (netcheck equivalent)
- v0.5.0: DNS diagnostics
- v0.6.0: Configuration management

**LocalAPI Coverage**: See `Documentation/LOCALAPI-COVERAGE.md` for comprehensive analysis of all available endpoints, CLI-only features, and implementation strategies.

## File Organization

```
Sources/TailscaleClient/
  TailscaleClient.swift          # Main client actor and error types
  Configuration/                 # Endpoint discovery and configuration
    TailscaleClientConfiguration.swift
    LocalAPIDiscovery.swift
  Transport/                     # HTTP/socket communication layer
    TailscaleTransport.swift
    UnixSocketTransport.swift
  Models/                        # Codable response models
    StatusResponse.swift
    StatusQuery.swift
    WhoIsResponse.swift
    PrefsResponse.swift
    PingResult.swift
    IPNNotify.swift              # IPN bus streaming models
  Platform/                      # Platform-specific helpers
    MacClientInfo.swift          # macOS loopback discovery (libproc)
    NetworkInterfaceDiscovery.swift  # TUN interface detection
  Support/                       # Utilities
    DecodingSupport.swift        # JSONDecoder extensions
  TailscaleClient.docc/          # DocC documentation catalog

Sources/tailscale-swift/         # Development CLI tool
  TailscaleSwift.swift           # Main entry point
  Status.swift, WhoIs.swift, Prefs.swift, Ping.swift, Health.swift, Metrics.swift

Tests/TailscaleClientTests/
  *DecodingTests.swift           # JSON decoding tests per model
  StatusAPITests.swift           # Transport and API tests with mocks
  NewEndpointAPITests.swift      # Tests for whois/prefs/ping/metrics
  ErrorHandlingTests.swift       # Error type and recovery tests
  NetworkInterfaceDiscoveryTests.swift
  TailscaleClientIntegrationTests.swift  # Gated by TAILSCALE_INTEGRATION=1
  TestSupport.swift              # XCTest helpers (XCTAssertThrowsErrorAsync)
  Fixtures/                      # Sample JSON responses
```