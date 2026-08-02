# Release Process

How versions are cut, tagged, published, and distributed.

## Versioning

- Semantic versioning. Pre-1.0: minor bumps may break API. Post-1.0: strict SemVer for the Stable tier; the `experimental` namespace is explicitly exempt (see [`ROADMAP.md`](../ROADMAP.md#stability--support-tiers)).
- Every release states in its notes which Tailscale versions it was tested against (the integration matrix results).

## Tagging convention

- **Annotated tags only**: `git tag -a v0.4.0 -m "v0.4.0: Reliability foundations"`. History note: v0.1.1 and v0.2.1 were lightweight; from v0.4.0 forward, annotated is required (the release workflow verifies).
- Tag name must exactly match a `## [x.y.z]` heading in `CHANGELOG.md` — the release workflow fails otherwise.

### One-time backfill

- **Retro-create the missing `v0.3.0` tag** on commit `caa5556` ("v0.3.0: IPN Bus Streaming") — the CHANGELOG has the entry but the tag was never pushed.
- Create GitHub Releases for the existing tags (v0.1.0–v0.3.1) with notes extracted from their CHANGELOG sections, so the Releases page tells the whole story.

## CHANGELOG discipline

Keep-a-Changelog format (already in place):

- Every user-visible change lands in `## [Unreleased]` in the same PR that makes it.
- Cutting a release = renaming `[Unreleased]` to `[x.y.z] - YYYY-MM-DD`, adding a fresh empty `[Unreleased]`, and updating README's Status section — one "Prepare vX.Y.Z release" commit.

## Release checklist

1. `[Unreleased]` → `[x.y.z]` in CHANGELOG; README Status + install pin updated; `Documentation/LOCALAPI-COVERAGE.md` status column updated for anything shipped; `.claude/skills/swift-tailscale-client/SKILL.md` refreshed if the API surface changed
2. `swift build && swift test` and `swift format lint --recursive Sources Tests` green; integration matrix green on stable versions
3. Merge the release PR; `git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`
4. The `release.yml` workflow (from v0.4.0) then:
   - verifies tag ↔ CHANGELOG entry match and that the tag is annotated
   - runs the full test suite
   - creates the GitHub Release with notes extracted from the CHANGELOG section
   - builds and attaches CLI binaries: macOS universal (arm64 + x86_64) and Linux x86_64 (since v0.6.0)
5. Bump the Homebrew formula (`dweekly/homebrew-tap`) manually — new tag URL + tarball sha256; steps and formula template in [`HOMEBREW.md`](HOMEBREW.md). (The workflow token cannot write to other repositories, so this stays manual.)
6. Verify Swift Package Index picked up the release and built docs (usually within hours; `.spi.yml` controls platforms and documentation targets)

## Distribution channels

| Channel | Mechanism | Status |
|---------|-----------|--------|
| Swift Package Manager | git tags; `.package(url:from:)` | live |
| Swift Package Index | automatic from tags; `.spi.yml` for platforms + hosted docs | `.spi.yml` added, SPI is the canonical docs host per release |
| GitHub Releases | `release.yml` automation (notes from CHANGELOG, CLI binaries attached) | live |
| Homebrew | tap `dweekly/homebrew-tap`, formula `tailscale-swift` building the CLI from the release tag | CLI is an executable product and the formula template is ready ([`HOMEBREW.md`](HOMEBREW.md)); tap repo + sha256 land with the v0.6.0 release. homebrew-core: post-1.0 aspiration once notability criteria are met |
| DocC | SPI (canonical, per-release) + GitHub Pages (bleeding-edge `main` snapshot) | Pages live |

## Announcement cadence

- **v0.6.0** (first `brew install` moment): PR to awesome-tailscale, post to r/Tailscale, Swift Forums "Related Projects"
- **v1.0.0**: Show HN, Tailscale community forum
- Every release: GitHub Release notes are the record; no separate blog required
