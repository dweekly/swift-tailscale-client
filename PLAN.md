# Swift Tailscale Client — Project Plan

## 1. Vision & Principles
- Build an unofficial, MIT-licensed Swift package that offers idiomatic async/await access to the Tailscale LocalAPI for Apple platforms.
- Focus the v0.1.0 MVP on providing a rock-solid `status` capability via a `TailscaleClient` actor; document limitations versus the official Go client.
- Publish high-quality DocC documentation, tests, and guidance for contributors, clearly labeling the project as a personal effort by David E. Weekly with no formal Tailscale affiliation.

## 2. Naming & Packaging Decisions
- Repository & package name: `swift-tailscale-client` (mirrors Swift package naming conventions and emphasizes unofficial nature).
- Primary Swift target/module: `TailscaleClient`.
- No bundled CLI to avoid confusion with the official `tailscale` binary; focus solely on a library deliverable.
- MIT license, with attribution and disclaimer about unofficial status in README, DocC, and source headers where appropriate.

## 3. MVP (v0.1.0) Scope & Deliverables
1. **Project Scaffolding**
   - Swift Package manifest targeting macOS 13+/iOS 16+/tvOS 16+/watchOS 9+.
   - Repository hygiene files: LICENSE (MIT), README, CHANGELOG, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, AGENTS, PLAN.
   - DocC catalog skeleton (`TailscaleClient.docc`) with intro page noting unofficial status.
2. **Transport Layer**
   - Configurable `TailscaleTransport` abstraction encapsulating Unix domain socket and loopback TCP fallback.
   - Auto-discovery of socket path and token (macOS) modeled on `safesocket.LocalTCPPortAndToken` and `paths.DefaultTailscaledSocket` with Swift equivalents.
   - Request pipeline injecting `Tailscale-Cap` header and optional Basic Auth token.
   - Explicit error taxonomy covering transport, auth, capability mismatch, HTTP status, and decoding errors.
3. **Status Endpoint Implementation**
   - Codable models mirroring the response payload from `/localapi/v0/status` (subset necessary for parity with `tailscale status --json`).
   - Public `TailscaleClient` actor exposing `func status(query: StatusQuery?) async throws -> StatusResponse`.
   - Request builder supporting query parameters such as `peers` and `dashboard` flags (documented subset).
   - Inline DocC documentation on usage, concurrency, and error cases.
4. **Testing Infrastructure**
   - Unit tests using stubbed transport to validate header injection, request formation, and decoding (fixtures derived from Go client JSON samples).
   - Integration test harness that can talk to a live tailscaled instance when available (guarded by `TAILSCALE_INTEGRATION=1`).
   - Mock server-based tests for CI, providing predictable `/localapi/v0/status` responses.
5. **Documentation & Examples**
   - README quickstart showing how to instantiate `TailscaleClient`, fetch status, and interpret key fields.
   - DocC tutorial for status retrieval and guidance on enabling integration testing.
6. **Automation & CI (post-local validation)**
   - GitHub Actions workflow for lint/build/test using mock server to avoid tailscaled dependency.
   - (Optional) docs workflow once DocC site is ready; defer until MVP is stable.

## 4. Detailed Work Breakdown
1. **Preparation**
   - Confirm repo name and metadata (SPM package name, SwiftPM compatibility matrix).
   - Draft README sections: project overview, unofficial disclaimer, installation, quickstart, roadmap.
2. **Transport Foundations**
   - Implement `SocketLocator` replicating default socket logic (macOS path `/var/run/tailscale/tailscaled.sock`, Linux variant stored for future use).
   - Implement token discovery for macOS GUI fallback; allow manual overrides via configuration struct.
   - Build `TailscaleTransport` protocol with production implementation using `URLSession` and custom `URLProtocol` for Unix socket connections.
   - Add unit tests verifying connection strategy selection and header injection.
3. **Domain Modeling**
   - Gather sample `status` JSON from Go client; define Swift `Codable` structs for key entities (`StatusResponse`, `PeerStatus`, `UserProfile`, etc.).
   - Annotate models with `Sendable` where applicable; document meaning of fields.
   - Write decoder tests using captured fixtures, including resilience to optional fields.
4. **Client API**
   - Create `TailscaleClientConfiguration` (socket path, timeout, capability version override, token override, transport override for tests).
   - Implement `TailscaleClient` actor holding configuration, performing request building, decoding, and error mapping.
   - Provide convenience overloads for default status call and advanced query options.
   - Add DocC doc comments and inline usage examples.
5. **Testing & Tooling**
   - Build mock transport returning fixture data; ensure unit tests cover success/failure cases.
   - Implement integration test that detects `TAILSCALE_INTEGRATION=1` and interacts with real LocalAPI using default configuration.
   - Ensure `swift test` succeeds with no environment prerequisites (integration test auto-skips when env var absent).
6. **Documentation & Publishing Prep**
   - Flesh out DocC intro article and API references.
   - Update README with disclaimers, usage snippet, integration test instructions, roadmap to post-MVP features (whois, prefs, streaming, etc.).
   - Add CHANGELOG entry for v0.1.0 (unreleased) summarizing initial functionality.
7. **CI Readiness**
   - Configure `.github/workflows/ci.yml` to run formatting, build, unit tests, and mock-based integration tests.
   - Defer real tailscaled integration in CI; document manual testing steps in CONTRIBUTING.

## 5. Roadmap Beyond v0.1.0
- **v0.2.0**: Extend coverage with `/whois`, `/ping`, `/query-feature`; enhance `StatusResponse` fidelity; improve error metadata.
- **v0.3.0**: Introduce streaming/IPN bus support via AsyncSequence wrappers; add Taildrop status endpoints.
- **v0.4.0+**: Preferences management, login/logout flows, diagnostics endpoints, optional lightweight CLI if user demand emerges (must not conflict with official tooling).
- Reassess naming and module boundaries as new functionality arrives; maintain backward compatibility commitments from v1.0 onward.

## 6. Risks & Mitigations
- **API Drift**: Track upstream LocalAPI changes; include capability version constant and document tested tailscaled versions.
- **Transport Parity**: macOS token discovery may require additional helper ports; mitigate via layered abstraction and fallback options.
- **Testing Dependencies**: Provide robust mock server to keep CI deterministic; document steps for manual testing with real tailscaled.
- **Unofficial Nature**: Reinforce disclaimers in README, DocC, and package metadata; avoid implying endorsement.

## 7. Immediate Next Actions
1. Rename repo/package references to `swift-tailscale-client` and update supporting docs (README, AGENTS, etc.).
2. Initialize Swift package structure, license, and contributor docs with unofficial disclaimer.
3. Implement transport abstraction and configuration scaffolding with unit tests.
4. Model `status` endpoint and expose primary async API.
5. Establish mock + real integration testing paths prior to CI onboarding.
