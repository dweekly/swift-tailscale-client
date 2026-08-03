# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It contains only what isn't authoritatively documented elsewhere; the index below says where everything else lives — read those files instead of duplicating their content here.

## Project Overview

This is an unofficial, MIT-licensed Swift 6 package providing async/await access to the Tailscale LocalAPI. It connects to an **existing** tailscaled daemon for monitoring tools, status widgets, dashboards, and developer utilities.

**Important**: This is NOT an official Tailscale product and has no affiliation with Tailscale Inc. Maintain this disclaimer in README, DocC, and source headers. This is NOT an embedded Tailscale implementation — use official [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift) for that.

## Where Things Live (single authoritative sources)

| Information | Authoritative source |
|---|---|
| Current version, release history, breaking changes | [`CHANGELOG.md`](CHANGELOG.md) (top entry = current release; `packageVersion` in `TailscaleClientConfiguration.swift` must match — CI enforces) |
| What remains to build; 1.0 criteria; stability tiers; API conventions; spike-first practice | [`ROADMAP.md`](ROADMAP.md) |
| User-facing overview, install, quickstarts, tool-choice table, runtime support matrix, env-var table | [`README.md`](README.md) |
| Per-endpoint status (implemented/planned/experimental/unsupported), upstream maturity + gates | [`Documentation/LOCALAPI-COVERAGE.md`](Documentation/LOCALAPI-COVERAGE.md), generated from [`Documentation/endpoints.json`](Documentation/endpoints.json) — **edit the JSON, never the generated tables** |
| Canonical integration guide (humans + agents); CLI command list | [`Documentation/INTEGRATING.md`](Documentation/INTEGRATING.md) |
| Test harness, fixture capture, hermetic headscale matrix, write-test gating | [`Documentation/TESTING.md`](Documentation/TESTING.md) |
| Release process (tags, CHANGELOG discipline, distribution) | [`Documentation/RELEASING.md`](Documentation/RELEASING.md) |
| AI-agent adoption skill (kept in sync with the public API) | `.claude/skills/swift-tailscale-client/SKILL.md` (thin adapter over INTEGRATING.md, like `AGENTS.md` and `llms.txt`) |

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

# Docs-as-code gates (CI runs all of these)
python3 Scripts/generate-endpoint-docs.py --check   # generated tables in sync + no contradictions
python3 Scripts/verify-upstream-maturity.py         # maturity/gates/capability vs pinned upstream commit
./Scripts/check-release-consistency.sh              # advertised versions agree (Bash 3.2-compatible)
python3 Scripts/check-recipe-snippets.py            # recipe articles match compiled Examples/Recipes
```

## Architecture

Layered design under `Sources/TailscaleClient/`:

1. **Transport** (`Transport/`) — `TailscaleTransport` protocol; `URLSessionTailscaleTransport` (unix socket + loopback TCP); `UnixSocketTransport` (raw POSIX sockets, Darwin + Glibc, poll-based reads for cancellation); pure wire-format types (`HTTPWireFormat`, `HTTPHeadBuffer`, `NewlineFramer`, `ChunkedTransferDecoder`) unit-tested in isolation. Handles header injection (`Tailscale-Cap`, `Authorization`, `Host: local-tailscaled.sock`).
2. **Configuration & Discovery** (`Configuration/`) — `TailscaleClientConfiguration` (endpoint, auth token, capability version pinned to a verified upstream commit, timeout, transport); `LocalAPIDiscovery` (env vars → platform methods → fallback socket paths).
3. **macOS platform discovery** (`Platform/MacClientInfo.swift`) — App Store GUI discovery is **opt-in** (`default(allowMacOSAppStoreDiscovery: true)`) because it triggers a TCC popup; libproc first (~5ms), Group Containers fallback. Respects `TAILSCALE_SAMEUSER_PATH`/`_DIR`, `TAILSCALE_SKIP_LIBPROC`; `TAILSCALE_DISCOVERY_DEBUG=1` for stderr logging (all discovery logging is secret-redacted via `Support/DiscoveryLog.swift`).
4. **Models** (`Models/`) — tolerant `Codable` mirrors of LocalAPI JSON; all `Sendable`.
5. **Client** — `actor TailscaleClient` (`TailscaleClient.swift` plus surface extensions `ServeAPI.swift`, `StableParityAPI.swift`, `Experimental.swift`); one shared status-error mapping produces the typed `TailscaleClientError` cases.
6. **Netcheck** (`Netcheck/`) — client-side STUN (RFC 8489) probe; no LocalAPI equivalent exists.
7. **Interface discovery** (`Platform/NetworkInterfaceDiscovery.swift`) — `getifaddrs`-based TUN matching, exposed via `StatusResponse.interfaceName`/`interfaceInfo`.

`Sources/tailscale-swift/` is the CLI executable product; `Tests/TailscaleClientTests/` holds unit + gated integration suites with fixtures under `Fixtures/`; `Examples/` packages are CI-built.

### Key Patterns

- **Swift 6 strict concurrency**: all public types `Sendable`; `actor` for state isolation; task-locals for request-scoped state (`withAuditReason`)
- **Async/await throughout**: no callbacks or completion handlers
- **Protocol-oriented transport**: inject `MockTransport` (from the `TailscaleClientMocks` product) in tests
- **Graceful discovery fallback** and **tolerant decoding** (unknown enum values/fields never fail; `omitempty` booleans decode absent-as-false)
- **Secrets never reach diagnostic surfaces** — logging, `description`, and reflection are all redacted and regression-tested

## Testing Strategy

- **Unit tests**: `MockTransport` + fixture JSON from `Tests/TailscaleClientTests/Fixtures/`
- **Integration tests**: gated by `TAILSCALE_INTEGRATION=1` (read-only) and `TAILSCALE_INTEGRATION_WRITE=1` (mutations — hermetic headscale lanes only, never a real tailnet)
- **Patterns**: `assertThrowsErrorAsync` (TestSupport.swift) for async error assertions; `RequestRecorder` actor to verify requests
- **CI**: hosted lanes are hermetic (mocks + headscale); the self-hosted macOS lane talks to a real tailnet with read-only tests. Details in `Documentation/TESTING.md`.

## Development Guidelines

- **Spike before you ship** (see ROADMAP.md): exercise every new endpoint against a real daemon, cross-check `tailscale/tailscale` source at the pinned commit in `endpoints.json`, capture fixtures from real responses, record symbol/maturity/gate in the manifest — CI verifies all three
- **Never manually edit Xcode project files**: have the human user perform Xcode modifications
- **Platform-specific code**: `#if os(macOS)` for macOS-specific discovery logic
- **Error handling**: detailed context (transport errors carry underlying errors; decoding errors carry the body; typed cases for 403/404-peer/412/429)
- **Documentation**: DocC comments with usage examples on all public APIs; when the public API changes, update INTEGRATING.md and its adapters (skill, AGENTS.md, llms.txt) in the same PR
- **Environment variable overrides** for all configuration (table in README)
- **Directory hygiene**: `Documentation/` is committed project docs; `docs/` is gitignored DocC output — never put project docs there
- **Commit identity**: `git config user.email noreply@anthropic.com && git config user.name Claude` before committing as an agent

## Project Context

- **Primary use case**: the Network Weather (NWX) macOS diagnostics app — read-heavy monitoring first
- **Maintainer**: David E. Weekly (security/conduct contact: david@weekly.org)
- **Agent-environment notes**: the env proxy blocks agent tag pushes (maintainer pushes tags; keep pushes to ≤3 tags so GitHub emits push events); the hermetic headscale matrix is dispatched via `integration-linux.yml` on a branch ref
