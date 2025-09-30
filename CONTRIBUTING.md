# Contributing to swift-tailscale-client

Thanks for your interest in improving this unofficial Swift client for the Tailscale LocalAPI! This project is maintained by David E. Weekly and is not affiliated with Tailscale Inc.

## Ground Rules
- Be respectful and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Keep discussions and contributions focused on the library; CLI tooling intentionally remains out of scope.
- Make sure all public-facing docs (README, DocC, commit messages) preserve the project's unofficial disclaimer.

## Development Workflow
1. Fork and clone the repository.
2. Create a feature branch off `main`.
3. Run the formatter and tests before opening a pull request:
   ```bash
   swift format --in-place --recursive Sources Tests
   swift test
   ```
   To check formatting without modifying files:
   ```bash
   swift format lint --recursive Sources Tests
   ```
4. If you have Tailscale installed locally, you may run integration tests against a live daemon:
   ```bash
   TAILSCALE_INTEGRATION=1 swift test --filter TailscaleClientIntegrationTests
   ```
   These tests should **not** run in CI by default.
5. Update documentation and changelog entries relevant to your changes.
6. Submit a pull request describing the motivation, changes, and testing performed.

## Coding Standards
- Swift 6 strict concurrency; actors for shared mutable state.
- Public types must be `Sendable` where applicable.
- Use `Codable` models for JSON payloads; include fixture-backed tests for each model.
- Avoid adding external dependencies unless absolutely necessary.

## Documentation
- Update DocC articles and README examples when APIs change.
- Include doc comments for all public APIs describing usage, error cases, and concurrency notes.

## Reporting Issues
If you encounter bugs or have feature requests, open an issue with:
- Expected vs actual behavior
- Steps to reproduce (including tailscaled version, if relevant)
- Any logs or JSON payloads (with sensitive data redacted)

Thanks for helping make `swift-tailscale-client` useful for the community!
