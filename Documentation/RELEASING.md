# Release Process

How versions are cut, tagged, published, and distributed.

## Versioning

- Semantic versioning. Pre-1.0: minor bumps may break API. Post-1.0: strict SemVer for the Stable tier; the `experimental` namespace is explicitly exempt (see [`ROADMAP.md`](../ROADMAP.md#stability--support-tiers)).
- Every release states in its notes which Tailscale versions it was tested against (the integration matrix results).

## Tagging convention

- **Annotated tags only**: `git tag -a v1.0.0 -m "v1.0.0: Production-grade Swift Tailscale LocalAPI client"`. Annotated tags are strictly required and verified by release automation.
- Tag name must exactly match a `## [x.y.z]` heading in `CHANGELOG.md` — the release workflow fails otherwise.
- **Push at most three tags per `git push`**: GitHub emits no push events for pushes containing more than three tags, which causes `release.yml` to silently not run.
- **Published git tags are strictly immutable**: Once pushed, a tag is **never moved or deleted**. In Swift Package Manager, moving a tag breaks `Package.resolved` fingerprint validation for all consumers.

## Release & Governance Roles

- **Primary Release Owner**: David E. Weekly (`@dweekly`, [david@weekly.org](mailto:david@weekly.org)).
- **Designated Backup Maintainer**: [security-backup@weekly.org](mailto:security-backup@weekly.org) / repository co-admin. Has authority to rehearse release checklists, triage security disclosures, and cut emergency patch releases if the primary owner is unavailable.

## CHANGELOG discipline

Keep-a-Changelog format (already in place):

- Every user-visible change lands in `## [Unreleased]` in the same PR that makes it.
- Cutting a release = renaming `[Unreleased]` to `[x.y.z] - YYYY-MM-DD`, adding a fresh empty `[Unreleased]`, and updating README's Status section — one "Prepare vX.Y.Z release" commit.

## 1.0 Automated Pre-Release Gates & Verification Checklist

Before cutting a release candidate or final release, execute the 1.0 verification toolchain:

1. **Docs & Version Consistency Gate**:
   `./Scripts/check-release-consistency.sh vX.Y.Z`
2. **API Compatibility Baseline Gate**:
   `./Scripts/check-api-baseline.sh`
3. **Upstream Maturity & Endpoint Coverage Sync**:
   `python3 Scripts/verify-upstream-maturity.py`
   `python3 Scripts/generate-endpoint-docs.py --check`
4. **Recipe Snippet & Documentation Verification**:
   `python3 Scripts/check-recipe-snippets.py`
   `swift test --package-path Examples/Recipes`
5. **DocC Documentation Coverage Floor (Strict)**:
   `swift package generate-documentation --target TailscaleClient --warnings-as-errors`
6. **Format & Test Suite with Code Coverage (>=85%)**:
   `swift format lint --strict --recursive Sources Tests`
   `swift test --enable-code-coverage`
7. **Governance, DCO & Security Policy Rehearsal**:
   `python3 Scripts/check-governance.py --dco-range origin/main..HEAD`
8. **Exact-SHA Release Evidence Aggregation & Simulated Rehearsal**:
   `python3 Scripts/aggregate-release-evidence.py --tag vX.Y.Z --simulate-tag`
   Verify that all 6 release evidence gates pass without unexpected skips.
9. **External Technical Review Sign-Off**:
   Verify that `Documentation/EXTERNAL-REVIEW.md` is signed off and all blocking findings are closed.

## Tagging and Publication Flow

1. Merge release PR into `main`.
2. Tag the exact tested commit: `git tag -a vX.Y.Z -m "vX.Y.Z: ..." && git push origin vX.Y.Z`
3. The `release.yml` workflow then:
   - verifies tag ↔ CHANGELOG entry match and that the tag is annotated
   - runs the full test suite
   - creates the GitHub Release with notes extracted from the CHANGELOG section
   - builds and attaches CLI binaries: macOS universal (arm64 + x86_64) and Linux x86_64
   - generates and attaches `SHA256SUMS.txt` manifest
4. Bump the Homebrew formula (`dweekly/homebrew-tap`) manually — update tag URL + tarball sha256 per [`HOMEBREW.md`](HOMEBREW.md).
5. Verify Swift Package Index picked up the release and built docs (`.spi.yml` controls platforms).

## Emergency Rollback & Post-Release Patch Protocol

If a release is found to contain a critical security vulnerability or regression after tag publication:
1. **Never delete or move the published tag.**
2. Add a prominent notice to the GitHub Release marking it as **Yanked / Deprecated** and recommending the immediate upgrade target.
3. Create a hotfix branch from the tag: `git checkout -b hotfix/vX.Y.(Z+1) vX.Y.Z`.
4. Apply targeted fix and regression test; run `./Scripts/check-release-consistency.sh vX.Y.(Z+1)` and `aggregate-release-evidence.py`.
5. Tag and push `vX.Y.(Z+1)`. Update Homebrew formula immediately.

## Distribution channels

| Channel | Mechanism | Status |
|---------|-----------|--------|
| Swift Package Manager | git tags; `.package(url:from:)` | live |
| Swift Package Index | automatic from tags; `.spi.yml` for platforms + hosted docs | `.spi.yml` added, SPI is the canonical docs host per release |
| GitHub Releases | `release.yml` automation (notes from CHANGELOG, CLI binaries attached) | live |
| Homebrew | tap `dweekly/homebrew-tap`, formula `tailscale-swift` building the CLI from the release tag | live |
| DocC | SPI (canonical, per-release) + GitHub Pages (bleeding-edge `main` snapshot) | Pages live |

## Announcement cadence

- **v1.0.0**: Show HN, Tailscale community forum, Swift Forums "Related Projects"
- Every release: GitHub Release notes are the record; no separate blog required
