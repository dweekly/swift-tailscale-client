# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial, MIT-licensed Swift 6 package providing async/await access to the Tailscale LocalAPI for Apple platforms. The project is in active development toward v0.1.0, which focuses on the `/localapi/v0/status` endpoint.

**Important**: This is NOT an official Tailscale product and has no affiliation with Tailscale Inc. Maintain this disclaimer in README, DocC, and source headers.

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
   - Two-tier discovery strategy for locating `sameuserproof-<port>-<token>` files:
     1. **lsof probe** (PRIMARY): Runs `/usr/sbin/lsof -n -a -c IPNExtension -F n` to find open files (~140ms)
        - Works because lsof is Apple-signed with special entitlements (`anchor apple`, `com.apple.rootless.datavault.metadata`)
        - Parses the `-F n` (field output) format to extract file paths
     2. **Filesystem fallback**: Enumerates `~/Library/Group Containers` and `/Library/Group Containers` (~2s)
        - Used when lsof is unavailable or disabled via `TAILSCALE_SKIP_LSOF=1`
   - Respects `TAILSCALE_SAMEUSER_PATH`, `TAILSCALE_SAMEUSER_DIR`, and `TAILSCALE_SKIP_LSOF` environment variables
   - Use `TAILSCALE_DISCOVERY_DEBUG=1` for verbose logging to stderr
   - Note: libproc APIs (`proc_pidfdinfo`) were considered but fail due to SIP restrictions on cross-process file descriptor inspection

4. **Models** (`Models/`)
   - `StatusResponse`: Strongly-typed Codable models mirroring LocalAPI JSON responses
   - `StatusQuery`: Query parameters for status endpoint (e.g., `includePeers`)
   - All models are `Sendable` for Swift 6 strict concurrency

5. **Client API** (`TailscaleClient.swift`)
   - Public `actor TailscaleClient` providing thread-safe async access
   - Currently exposes `func status(query:) async throws -> StatusResponse`
   - Maps transport errors to `TailscaleClientError` (`.transport`, `.unexpectedStatus`, `.decoding`)

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

## Project Status (v0.1.1)

**Current focus**: Polish, bug fixes, and documentation improvements after v0.1.0 release.

**v0.1.0 shipped**:
- Full `/localapi/v0/status` endpoint with strongly-typed models
- Transport abstraction (Unix socket + TCP loopback)
- macOS LocalAPI discovery (lsof probe + filesystem fallback)
- Development CLI tool (`tailscale-swift status`)
- DocC documentation deployed to GitHub Pages

**Roadmap** (see `ROADMAP.md`):
- v0.1.1: Polish & fixes
- v0.2.0: `/whois`, `/ping`, `/prefs` endpoints
- v0.3.0: Taildrop support
- v0.4.0+: Streaming IPN bus, configuration management

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
  Platform/                      # Platform-specific helpers
    MacClientInfo.swift          # macOS loopback discovery
  Support/                       # Utilities
    DecodingSupport.swift        # JSONDecoder extensions
  TailscaleClient.docc/          # DocC documentation catalog

Tests/TailscaleClientTests/
  TailscaleClientTests.swift
  StatusAPITests.swift           # Transport and API tests with mocks
  StatusResponseDecodingTests.swift
  TailscaleClientConfigurationTests.swift
  TailscaleClientIntegrationTests.swift  # Gated by TAILSCALE_INTEGRATION=1
  TestSupport.swift              # XCTest helpers
  Fixtures/                      # Sample JSON responses
```