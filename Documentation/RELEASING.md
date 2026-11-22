# Release Process

How versions are cut, tagged, published, and distributed.

The commands below use `v1.1.0`, the most recent release; substitute the version being released. A release can add its own acceptance plan, as [PLAN-1.1.0.md](PLAN-1.1.0.md) did for 1.1.0.

## Versioning

- Semantic versioning. Pre-1.0: minor bumps may break API. Post-1.0: strict SemVer for the Stable tier; the `experimental` namespace is explicitly exempt (see [`ROADMAP.md`](../ROADMAP.md#stability--support-tiers)).
- Every release states in its notes which Tailscale versions it was tested against.

## Tagging convention

- **Annotated tags only**: `git tag -a v1.1.0 <sha> -m "v1.1.0: ..."`. Release automation rejects lightweight tags and empty annotations.
- Tag name must exactly match a `## [x.y.z]` heading in `CHANGELOG.md`, and that section must not be empty — the release workflow fails otherwise.
- **Push at most three tags per `git push`**: GitHub emits no push events for pushes containing more than three tags, which causes `release.yml` to silently not run.
- **Published git tags are strictly immutable**: Once pushed, a tag is **never moved or deleted**. In Swift Package Manager, moving a tag breaks `Package.resolved` fingerprint validation for all consumers. A failed release run is repaired by re-running it or by attaching its validated assets by hand (below), never by re-tagging.

## Release & Governance Roles

- **Primary Release Owner**: David E. Weekly (`@dweekly`, [david@weekly.org](mailto:david@weekly.org)).
- **Designated Backup Maintainer**: [security-backup@weekly.org](mailto:security-backup@weekly.org) / repository co-admin. Has authority to rehearse release checklists, triage security disclosures, and cut emergency patch releases if the primary owner is unavailable.

## CHANGELOG discipline

Keep-a-Changelog format:

- Every user-visible change lands in `## [Unreleased]` in the same PR that makes it.
- Cutting a release is one "Prepare vX.Y.Z release" commit (see step 1 below).

## What the release workflow does

[`release.yml`](../.github/workflows/release.yml) has four jobs. On a `v*` tag push all four run; on a manual dispatch (a rehearsal) the first three run and `publish` is skipped.

| Job | Needs to be true | Fails when |
|---|---|---|
| `validate` | Tag is annotated with a message (tag push only); checkout equals the tagged commit and is clean; the `All Required Checks` check run on that commit succeeded; `## [x.y.z]` exists in CHANGELOG; `check-release-consistency.sh vX.Y.Z` passes; `swift test` passes; the CHANGELOG section is non-empty | any of these is false |
| `build-macos-universal` | Universal (arm64 + x86_64) `tailscale-swift` builds; `--help` prints `OVERVIEW:` and `SUBCOMMANDS:`; `--version` prints exactly `x.y.z`; no crash without a daemon | build or smoke test fails |
| `evidence` | `SHA256SUMS.txt` verifies; a **successful `ci.yml` run on the exact commit** exists; its `test-report-test_macos` and `test-report-test_tsan` artifacts download; `aggregate-release-evidence.py --validate` passes all six gates | no such CI run, a report is missing or altered, any gate fails |
| `publish` (tag push only, the only job with `contents: write`) | Validated assets from `evidence`; no already-published release for the tag | the release already exists as non-draft, or a `gh` call fails |

`publish` creates a draft (or reuses an existing draft), uploads the archive, `SHA256SUMS.txt` and `release-evidence-vX.Y.Z.json` with `--clobber`, then sets `--draft=false`. Every `gh` call passes `--repo` explicitly, because that job has no checkout (the v1.0.0 run failed there for lack of a repository).

A re-run of a tag-push run uses `release.yml` and the scripts as they are at the tagged commit. A fix merged afterwards does not reach that tag's run.

## Pre-tag procedure

Run from a checkout of `main`. `EV` is a scratch directory outside the checkout (downloaded artifacts must never sit inside it, or the clean-tree checks fail).

1. **Prepare the release commit** in one PR: rename `## [Unreleased]` to `## [1.1.0] - YYYY-MM-DD` and add a fresh empty `## [Unreleased]` above it; set `packageVersion = "1.1.0"` in `Sources/TailscaleClient/Configuration/TailscaleClientConfiguration.swift`; change every `from: "1.0.0"` pin (README, `.claude/skills/swift-tailscale-client/SKILL.md`, AGENTS.md, llms.txt, INTEGRATING.md, `Examples/Recipes/Package.swift`, DocC `GettingStarted.md`); change the `swift-tailscale-client version:` line in `Documentation/LOCALAPI-COVERAGE.md`; update README's Status section. Then:
   ```sh
   ./Scripts/check-release-consistency.sh v1.1.0
   ```
   must end with `Release consistency check passed (version 1.1.0).` Before this commit exists it fails with `DRIFT release tag (v1.1.0) != documented version (1.0.0)`; that is the expected pre-preparation result.
2. **Merge it and let nothing else land on `main` until its CI finishes.** `ci.yml` cancels an in-progress `main` run when another commit is pushed, and a cancelled run is not evidence. Record the commit:
   ```sh
   git fetch origin && SHA=$(git rev-parse origin/main)
   ```
3. **Confirm CI on the exact commit.** Each must print as shown:
   ```sh
   gh run list --workflow ci.yml --commit "$SHA" --status success --limit 1 --json databaseId --jq '.[0].databaseId'   # a run ID
   gh api "repos/dweekly/swift-tailscale-client/commits/$SHA/check-runs?per_page=100" \
     --jq '.check_runs[] | select(.name == "All Required Checks") | .conclusion'                              # success
   ```
   If the run was cancelled, `gh run rerun <run-id>` and wait for it. CI already runs the docs gates (`check-release-consistency.sh`, `generate-endpoint-docs.py --check`, `verify-upstream-maturity.py`, `check-recipe-snippets.py`, `check-model-conformance.py`, the release-tooling self-tests), `check-api-baseline.sh` against `v1.0.0`, strict DocC with coverage floors, `swift format lint --strict`, the 85% coverage floor, TSan, and the iOS/tvOS/watchOS builds; each is part of `All Required Checks`.
4. **Rehearse the release workflow** on that commit. It runs every step except `publish` and needs no write permission:
   ```sh
   gh workflow run release.yml --ref main -f ref="$SHA"            # tag defaults to v<packageVersion>
   gh run list --workflow release.yml --event workflow_dispatch --limit 1   # note the run ID
   gh run watch <run-id> --exit-status
   ```
   Expect `validate`, `build-macos-universal` and `evidence` to succeed and `publish` to show as skipped. Inspect the would-be assets:
   ```sh
   gh run download <run-id> -n rehearsal-release-assets-v1.1.0 -D "$EV/rehearsal"
   (cd "$EV/rehearsal" && shasum -a 256 -c SHA256SUMS.txt)              # ...macos-universal.tar.gz: OK
   jq '.gating_verdict.passed, .tag.simulated, .commit.sha' "$EV/rehearsal/release-evidence-v1.1.0.json"   # true, true, "$SHA"
   ```
5. **Optionally reproduce the evidence locally** with the same CI artifacts (the rehearsal already did this on a runner). Without `--validate` the script only writes the file and exits 0 whatever the verdict, and without artifacts and reports it cannot pass:
   ```sh
   RUN=$(gh run list --workflow ci.yml --commit "$SHA" --status success --limit 1 --json databaseId --jq '.[0].databaseId')
   gh run download "$RUN" --pattern 'test-report-*' --dir "$EV/test-reports"
   gh api --paginate --slurp "repos/dweekly/swift-tailscale-client/actions/runs/$RUN/jobs?filter=latest&per_page=100" \
     | jq '{check_runs: [.[].jobs[]]}' > "$EV/ci-checks.json"
   python3 Scripts/aggregate-release-evidence.py --tag v1.1.0 --simulate-tag --commit "$SHA" \
     --ci-data "$EV/ci-checks.json" --test-reports "$EV/test-reports" \
     --artifacts-dir "$EV/rehearsal" --output "$EV/evidence.json" --validate
   ```
   It must print `Verdict: SUCCESS (ALL 6 GATES PASSED)` and exit 0. On a laptop the `--artifacts-dir` archive must be one whose `--version` prints `1.1.0`.
6. **Governance and DCO** (advisory; `release.yml` does not run it):
   ```sh
   python3 Scripts/check-governance.py --dco-range v1.0.0.."$SHA"
   ```
   It lists every commit since the previous release without a `Signed-off-by:` trailer, merge commits included. Whether unsigned history blocks a tag is the release owner's decision; record it in the release PR.
7. **NWX compatibility and review findings**: record a smoke test of the real NWX integration and resolve blocking technical findings. Keep `Documentation/EXTERNAL-REVIEW.md` honest about review status.

## Tag and publish

```sh
git tag -a v1.1.0 "$SHA" -m "v1.1.0: <one-line summary>"
git cat-file -t v1.1.0                          # tag
git rev-parse 'v1.1.0^{commit}'                 # equals $SHA
git push origin v1.1.0                          # one tag per push
gh run list --workflow release.yml --event push --limit 1
gh run watch <run-id> --exit-status
```

After it succeeds:

```sh
gh release view v1.1.0 --json isDraft,assets --jq '.isDraft, [.assets[].name]'
#   false, ["release-evidence-v1.1.0.json","SHA256SUMS.txt","tailscale-swift-v1.1.0-macos-universal.tar.gz"]
gh release download v1.1.0 -D "$EV/published" && (cd "$EV/published" && shasum -a 256 -c SHA256SUMS.txt)
jq '.gating_verdict.passed, .tag.is_annotated, .tag.simulated, .tag.target_commit, .required_lanes.test_macos.test_summary' \
  "$EV/published/release-evidence-v1.1.0.json"
#   true, true, null, "$SHA", executed > 0 with failures 0 and unexpected_skips 0
```

Then bump the Homebrew formula (`dweekly/homebrew-tap`) per [`HOMEBREW.md`](HOMEBREW.md) and verify that Swift Package Index picked up the release and built docs (`.spi.yml` controls platforms).

## If the release workflow fails

The tag stays where it is in every case.

- **`validate`, `build-macos-universal` or `evidence` failed** (nothing has been published, and no draft exists yet): if the cause is outside the tagged tree (a flaky test, a cancelled or not-yet-finished CI run on the commit, a runner outage), fix that and run `gh run rerun <release-run-id> --failed`. If the cause is in the tagged tree (a script or `release.yml` bug), a re-run repeats it: fix it on `main` and release the next patch version.
- **`publish` failed**: `gh run rerun <release-run-id> --failed` is safe. It reuses the validated `release-assets-v1.1.0` artifact from the same run, edits an existing draft instead of creating a second one, re-uploads with `--clobber`, and refuses to touch a release that is already published. If the re-run cannot succeed, attach the same validated files by hand:
  ```sh
  gh run download <release-run-id> -n release-assets-v1.1.0 -D "$EV/manual"
  gh run download <release-run-id> -n release-notes -D "$EV/manual-notes"
  (cd "$EV/manual" && shasum -a 256 -c SHA256SUMS.txt)
  gh release create v1.1.0 --repo dweekly/swift-tailscale-client --verify-tag --title v1.1.0 \
    --notes-file "$EV/manual-notes/notes.md" "$EV"/manual/*      # or, if a draft exists: gh release upload ... --clobber, then gh release edit v1.1.0 --draft=false
  ```
  Never upload rehearsal artifacts to a release: their evidence carries `"simulated": true`.

`attach-binaries.yml` rebuilds and attaches only the archive; it does not produce `SHA256SUMS.txt` or release evidence, so prefer the steps above.

## Emergency Rollback & Post-Release Patch Protocol

If a release is found to contain a critical security vulnerability or regression after tag publication:
1. **Never delete or move the published tag.**
2. Add a prominent notice to the GitHub Release marking it as **Yanked / Deprecated** and recommending the immediate upgrade target.
3. Create a hotfix branch from the tag: `git checkout -b hotfix/vX.Y.(Z+1) vX.Y.Z`.
4. Apply targeted fix and regression test; follow the pre-tag procedure above for `vX.Y.(Z+1)`.
5. Tag and push `vX.Y.(Z+1)`. Update Homebrew formula immediately.

## Distribution channels

| Channel | Mechanism | Status |
|---------|-----------|--------|
| Swift Package Manager | git tags; `.package(url:from:)` | live |
| Swift Package Index | automatic from tags; `.spi.yml` for platforms + hosted docs | `.spi.yml` added, SPI is the canonical docs host per release |
| GitHub Releases | `release.yml` automation (notes from CHANGELOG, macOS CLI binary, checksums, evidence attached) | live |
| Homebrew | tap `dweekly/homebrew-tap`, formula `tailscale-swift` building the CLI from the release tag | live |
| DocC | SPI (canonical, per-release) + GitHub Pages (bleeding-edge `main` snapshot) | Pages live |

## Announcement cadence

- Major releases: Show HN, Tailscale community forum, Swift Forums "Related Projects"
- Every release: GitHub Release notes are the record; no separate blog required

## CI test evidence

The macOS unit and macOS TSan jobs wrap the root package's `swift test` in
`Scripts/ci-test-report.py` and upload `test-report-test_macos` and
`test-report-test_tsan`. Each artifact contains the original test log and a JSON
report with its SHA-256 digest, source commit, CI run ID, toolchain,
executed/failed/skipped counts, and named skip reasons. Example packages built
and tested in the same job are not wrapped and do not appear in the reports;
they gate the release through `All Required Checks`. Releases are qualified on
Apple platforms; Linux builds, Linux binaries, and the manual Headscale workflow
are outside the release gates.

The release workflow downloads these artifacts from a successful `ci.yml` run
on the exact release commit. It passes that run's job results through `--ci-data`
and the downloaded directory through `--test-reports` to the evidence aggregator.
The aggregator checks each report against its log and rejects missing members,
wrong commits, mixed runs, duplicate reports, test failures, and unexplained
skips. Required API-baseline job success is also recorded; unexecuted conformance
checks are labeled unverified.

Expected skips are narrowly allowlisted in `Scripts/ci-test-report.py`: disabled
live suites in unit jobs, older-version endpoint gaps, and named limitations of
the disposable Headscale environment. Missing write/login permission, missing
ETags, and skipped critical regression suites remain failures. Add an exception
only after reviewing the exact test, reason, and environment; do not relax the
policy merely to make a release pass.

To exercise the collector locally (this is local evidence, not a CI release pass):

```sh
python3 Scripts/ci-test-report.py --lane test_macos --member unit \
  --output "$EV/tailscale-tests/unit.json" -- swift test
python3 Scripts/test-ci-test-report.py
python3 Scripts/test-release-rehearsal.py
python3 Scripts/test-soak-verification.py
```
