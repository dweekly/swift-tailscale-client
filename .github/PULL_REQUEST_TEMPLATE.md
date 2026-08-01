# Summary

<!-- What does this change and why? Link the issue if there is one. -->

## Checklist

- [ ] `swift test` passes locally
- [ ] `swift format lint --recursive Sources Tests` is clean
- [ ] New endpoints were spiked against a real tailscaled first, with fixtures captured from real (sanitized) responses — see [Documentation/TESTING.md](../blob/main/Documentation/TESTING.md)
- [ ] Public APIs have DocC comments; `Documentation/LOCALAPI-COVERAGE.md` status updated if endpoint coverage changed
- [ ] `CHANGELOG.md` `[Unreleased]` section updated for user-visible changes

## Tailscale versions tested against

<!-- e.g. 1.92.3 (Homebrew, macOS); headscale integration suite -->
