# Contributing to swift-tailscale-client

Thanks for your interest in improving this unofficial Swift client for the Tailscale LocalAPI! This project is maintained by David E. Weekly and is not affiliated with Tailscale Inc.

## Ground Rules
- Be respectful and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Contributions to the library **and** the `tailscale-swift` CLI (a shipped executable product since v0.6.0) are both welcome; the CLI doubles as the library's reference consumer, so keep its commands thin wrappers over public library APIs.
- Make sure all public-facing docs (README, DocC, commit messages) preserve the project's unofficial disclaimer.

## Developer Certificate of Origin (DCO)
All contributions must include a sign-off in the commit message asserting agreement with the Developer Certificate of Origin (version 1.1):

```text
Signed-off-by: Jane Doe <jane.doe@example.com>
```

Using `git commit -s` automatically appends this trailer. By signing off, you certify that you have the right to submit the contribution under the project's MIT license.

## Development Workflow
1. Fork and clone the repository.
2. Create a feature branch off `main`.
3. Verify formatting and tests locally:
   ```bash
   swift format --in-place --recursive Sources Tests Examples
   swift test
   swift test --package-path Examples/Recipes
   ```
   To check formatting without modifying files:
   ```bash
   swift format lint --strict --recursive Sources Tests Examples
   ```
4. Check documentation compilation and coverage:
   ```bash
   swift package generate-documentation --target TailscaleClient --warnings-as-errors
   python3 Scripts/check-recipe-snippets.py
   ```
5. If you have Tailscale installed locally, you may run integration tests against a live daemon:
   ```bash
   TAILSCALE_INTEGRATION=1 swift test --filter TailscaleClientIntegrationTests
   ```
   These tests should **not** run in CI by default.
6. Update documentation and changelog entries relevant to your changes.
7. Submit a pull request describing the motivation, changes, and testing performed.

## Pull Request Merge Requirements
To be merged into `main`, every PR must satisfy these automated gates:
- **Test Suite**: 100% pass rate across unit, fault injection, and conformance test suites (`swift test`).
- **Strict DocC**: `swift package generate-documentation --target TailscaleClient --warnings-as-errors` passes cleanly with zero warnings, meeting CI coverage floors (Types ≥ 95%, Members ≥ 80%).
- **Docs-as-Code Synchronization**: `python3 Scripts/check-recipe-snippets.py` and `python3 Scripts/generate-endpoint-docs.py --check` pass without drift.
- **Source Compatibility Baseline**: No unintentional breaking changes to the public API surface in 1.x minor/patch releases.
- **Formatter**: Code passes `swift-format lint --strict`.

## Coding Standards & SemVer
- Swift 6 strict concurrency; actors for shared mutable state.
- Public types must be `Sendable` where applicable.
- Use `Codable` models for JSON payloads; include fixture-backed tests for each model.
- Lossless preservation: models modifying daemon configurations must retain unmodeled fields recursively.
- Post-1.0 SemVer commitment: No public breaking changes without a major version increment. New endpoints and additive functionality are introduced in minor releases (`1.x.0`). Bug fixes and security patches are released in patch versions (`1.0.x`).

## Reporting Issues
If you encounter bugs or have feature requests, open an issue with:
- Expected vs actual behavior
- Steps to reproduce (including tailscaled version, if relevant)
- Any logs or JSON payloads (with sensitive data redacted)

Thanks for helping make `swift-tailscale-client` useful for the community!

