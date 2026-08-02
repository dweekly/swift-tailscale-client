# Testing Strategy

How this package earns trust in an API surface that upstream labels unstable: spike against real daemons, capture real fixtures, unit-test the parsers to death, and run hermetic integration tests in CI against multiple tailscaled versions.

## The spike-first rule

No endpoint is implemented from documentation alone. The sequence for every new surface:

1. **Spike against a real tailscaled.** Hit the endpoint directly and observe reality:
   ```bash
   # Unix socket (Homebrew/standalone daemon)
   curl --unix-socket /var/run/tailscaled.socket \
        -H "Host: local-tailscaled.sock" \
        http://local-tailscaled.sock/localapi/v0/status

   # Streaming endpoints
   curl --no-buffer --unix-socket /var/run/tailscaled.socket \
        -H "Host: local-tailscaled.sock" \
        "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus?mask=1"
   ```
   Note status codes, headers (ETags!), transfer-encoding, empty bodies, and 204s — these are the things docs omit and tests must encode.
2. **Cross-check upstream source.** `ipn/localapi/` for the handler, `client/local/` for the Go client's request shape, `tailcfg`/`ipn` for types. The Go code is the contract; public docs lag it.
3. **Capture fixtures from the spike** (sanitized), never hand-typed from docs.
4. **Implement**, with the spike's corner cases written as tests first.

## Test harness architecture

### `TailscaleClientMocks` (shipped library product, v0.4.0)

Today `MockTransport` and `RequestRecorder` are duplicated privately across three test files, and every copy's `sendStreaming` just throws. They move into a public `TailscaleClientMocks` product that both our suite and downstream consumers use:

- **`MockTransport`** — scripted responses keyed by request matcher; records all requests.
- **Scripted streams** — `sendStreaming` yields a scripted sequence of lines with per-line delays, injected mid-stream errors, and controlled EOF, so the full `watchIPNBus` state machine (skip-bad-line, cancellation, reconnect) is unit-testable.
- **`RequestRecorder`** — actor capturing requests for assertion.
- **Fixture loaders** — shared helpers for the fixture library below.

Shipping mocks publicly is an adoption feature: apps depending on this package can test their own Tailscale-facing code without a daemon.

### Testable parsers (v0.5.0)

`UnixSocketTransport` currently in-lines HTTP response parsing and chunked-transfer decoding as private functions reachable only through a live socket. They become internal pure types — `HTTPResponseParser`, `ChunkedTransferDecoder` — fed `Data` in unit tests via `@testable import`.

## Fixture library

```
Tests/TailscaleClientTests/Fixtures/
  v1.92/
    status.json
    prefs.json
    watch-ipn-bus.ndjson     # captured stream, one Notify per line
  v1.94/
    ...
```

- Organized by the tailscaled version they were captured from, so decoding tests can assert compatibility across versions.
- Captured by a documented script (`Scripts/capture-fixtures.sh`, to be added with v0.4.0) that hits a real daemon through the spike commands above and sanitizes keys, IPs, hostnames, and user identifiers.
- Streaming fixtures are `.ndjson` — real line sequences including the initial-state burst.

## Corner-case checklist

Every transport/decoding change runs against this list; each item becomes a named test:

**Chunked transfer & HTTP framing**
- Chunk-size line split across two socket reads
- Chunk data split across reads; final `0\r\n\r\n` split across reads
- Trailers after the last chunk
- Response with no `Content-Length` and connection-close framing (HTTP/1.0 style)
- Status lines: 200 with empty body, 204 (e.g. `tka/modify`), 4xx/5xx with JSON and with plain-text bodies

**Streaming**
- Malformed JSON line mid-stream (must skip and report, not kill the stream)
- Oversized lines (>1 MB NetMap payloads)
- UTF-8 sequence split across read boundaries
- Stream cancellation mid-read; transport error mid-stream; server EOF
- Reconnect: backoff schedule, initial-state re-request, no event loss announcement

**Requests & errors**
- Timeout on connect and on read (`.timeout` error)
- 401/403 with and without auth token configured; auth header injection
- 404 on optional endpoints → `.endpointUnavailable` (with feature hint when `daemonFeatures()` has been called)
- `Host: local-tailscaled.sock` present on every request

**Decoding robustness (property/mutation tests)**
- Randomized truncation of every fixture must throw a typed error, never crash
- Random field deletion must either decode (optional field) or throw typed
- Unknown enum values decode to `.unknown(raw)` for every tolerant enum

## Coverage policy

- Coverage measured in CI (`swift test --enable-code-coverage` + `llvm-cov export`), with a hard floor enforced in `ci.yml` — no external service required. Codecov upload is a possible later addition for badges/patch checks.
- Floor: **55%** at v0.4.0 (measured baseline: 56.8% — `UnixSocketTransport` and `MacClientInfo` are integration-only until their v0.5.0 parser extraction), ratcheting to **75%** once those land and **85%** by v1.0. The floor tracks just under the measured baseline so regressions fail while honest measurement stays possible.
- Streaming path and transport parsers must reach full branch coverage — they are the historical blind spot (the v0.3.x headline features shipped untested).

## Integration testing

### Local (developer machines)

Unchanged: `TAILSCALE_INTEGRATION=1 swift test --filter TailscaleClientIntegrationTests` against whatever daemon is running locally. Env vars (`TAILSCALE_LOCALAPI_SOCKET`, etc.) select the target.

### Self-hosted macOS runner (live now, `integration.yml`)

The project has a self-hosted macOS runner with Tailscale installed and logged in, so the real-daemon integration suite runs in CI **today** — on pushes to main, same-repo PRs, and manual dispatch. Constraints that shape it:

- **Fork guard is mandatory.** Public repo + self-hosted runner means the workflow must never execute fork code; the job is gated on `github.event.pull_request.head.repo.full_name == github.repository`.
- **Read-only tests only.** The runner is attached to a real tailnet; the suite queries status/whois/ping/prefs/metrics and must not mutate daemon state. Write-API mutation tests (v0.8.0+) run exclusively in the hermetic headscale environment below.
- **Single version.** The runner tests whatever Tailscale version it has installed — valuable real-world signal, but not a version matrix.
- **Install-flavor aware discovery.** The workflow's "Configure LocalAPI access" step asks `tailscale debug local-creds` first — Tailscale's own discovery is authoritative for whatever flavor is installed. If the CLI is missing or its answer doesn't respond, it falls back through: unix sockets (Homebrew/standalone tailscaled), the standalone .pkg app (port from the `/Library/Tailscale/ipnport` symlink, token from the *contents* of the adjacent `sameuserproof-<port>` file — the runner user must be in the `admin` group to read it), then the App Store app (port and token encoded in the sameuserproof *filename* inside its Group Container — needs Full Disk Access). Every loopback candidate must answer an authenticated status request before it is used, because sameuserproof files from a previously installed flavor linger after switching and would otherwise be trusted blindly.

### Hermetic CI (v0.5.0, headscale in `integration.yml`)

The self-hosted runner gives one real macOS daemon; the version matrix and mutation-safe environment need hermetic infrastructure, and *hosted* macOS runners can't run tailscaled — **Linux runners can**. Design:

- ubuntu runner boots **headscale** (open-source control plane) in a container
- installs real `tailscaled`, runs it with `--tun=userspace-networking` (no root TUN needed)
- mints a pre-auth key locally against headscale, brings the node up
- runs the integration suite over the daemon's unix socket

Why headscale rather than the real control plane: hermetic, no secrets, safe on fork PRs, free to create/destroy tailnets per run. A separate, optional monthly job with an ephemeral auth key (repo secret) can sanity-check against the production control plane.

**Version matrix:** {current stable, previous stable, unstable} tailscaled. A matrix failure on unstable is an early warning of upstream drift, not a release blocker; failures on stable versions block release. Each release's notes state exactly which versions it was tested against.

### Mutation tests for write APIs (v0.8.0+)

Write endpoints (prefs PATCH etc.) get apply → verify → revert integration tests, run only in the headscale environment — never against a developer's real tailnet.

## What CI runs where

| Suite | PRs | Push to main | Nightly | Notes |
|-------|-----|--------------|---------|-------|
| Unit (mock-backed) | macOS (Linux at v0.5.0) | ✓ | ✓ | hermetic, no daemon |
| Platform build checks (iOS/tvOS/watchOS) | build-only | ✓ | — | declared platforms must compile |
| swift-format lint | ✓ | ✓ | — | against checked-in `.swift-format` |
| Integration (self-hosted macOS, real tailscaled) | same-repo PRs only | ✓ | — | read-only tests; fork-guarded |
| Integration (headscale, v0.5.0) | label-triggered | — | ✓ full matrix | Linux; hermetic; hosts mutation tests |
| Examples build | when touched | — | — | each `Examples/*` package |
