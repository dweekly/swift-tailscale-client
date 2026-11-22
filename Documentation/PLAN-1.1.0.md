# 1.1.0 release plan

**Shipped as `v1.1.0` on 2026-11-22** (tag on `548cf0e`; results in [#63](https://github.com/dweekly/swift-tailscale-client/pull/63)). The release criterion was: ship 1.1.0 when a Mac developer can open Peer Diagnostics on a clean checkout, try it with fixtures, select a real peer on an existing Tailscale installation, and explain the result using the public Swift API and published docs. The minor-version change is an additive ping-path API used by both the SwiftUI sample and `tailscale-swift ping`. If only fixes and documentation were ready, those would have shipped as 1.0.x. [Roadmap](../ROADMAP.md#110)

The release owner gathers the evidence below against the candidate commit and makes the tag decision. The feature author supplies fixtures, tests, source comments, and examples with the implementation. CI supplies build reports. A maintainer or pilot tester records observations that require a real Mac. The [release procedure](RELEASING.md) governs tagging and publication.

## Why

A Mac developer evaluating this package has no runnable answer to "can my app tell whether a peer is reachable, and how?" The library already returns the raw ping reply. It does not interpret it, and its one helper, `isDirect`, reports `true` for peer-relayed and TSMP replies because upstream sends `Endpoint` as an empty string instead of omitting it. 1.1.0 gives that developer one typed answer that matches the official CLI, one sample that shows it honestly, and evidence they can inspect. Any change that serves those three ends fits this plan. A change that only adds endpoints does not.

## Decisions

- **Path type.** `PingResult.path` returns `nil` for a failed ping and a `PingPath` otherwise: `.direct(endpoint:)`, `.peerRelay(endpoint:)`, `.derp(regionID:regionCode:)`, or `.unknown`. `PingPath` is `Sendable`, `Equatable`, and `Hashable`. `regionCode` is optional and is `nil` when upstream sends an empty code. Precedence follows `cmd/tailscale/cli/ping.go` at the pinned revision: nonempty `PeerRelay`, then nonzero `DERPRegionID`, then nonempty `Endpoint`. Empty strings and zero IDs count as absent.
- **What `.unknown` means.** The reply succeeded and named no path this release understands. TSMP, ICMP, and peerAPI pings never report one, so only a disco ping can produce the other cases. The symbol documentation says so, and the CLI prints the ping type in that case as upstream does.
- **`isDirect` is corrected, and ships in this release.** It is `true` exactly when `path` is `.direct`. The regression test decodes a captured disco reply with every field that reply carried, including the always-encoded empty ones. Separately labeled synthetic inputs cover combinations a captured reply does not contain.
- **peerAPI pings are corrected.** `PingType.peerAPI` sends `peerapi`, upstream's `tailcfg.PingPeerAPI` value. The daemon never answers the old spelling, so the call ran until the request timeout. A test asserts the query string sent for each ping type.
- **One ping is one measurement.** The official CLI repeats a disco ping until a direct endpoint appears. The sample sends a bounded burst and stops at the first reply classified `.direct`. Its maximum count, spacing, and per-ping timeout are named constants with their upstream source cited (`tailscale ping` defaults to a 5-second timeout, and the daemon sends no reply at all for an offline peer until the request ends), and selecting another peer or leaving live mode cancels it. The sample shows the last reply with its time and the number of pings sent, and never presents a single DERP reply as the peer's settled path. A ping result keeps its own timestamp: a later status refresh or watch reconnect does not make an old measurement look new. The burst lives in the sample. The library gains no retry helper.
- **Upstream pin.** Provenance is pinned to `tailscale/tailscale@1db8e79a8b00d9ea3a7459c92df07e3d565a8811`, capability 152, the head of upstream `main` when drift issue #45 was triaged. The daemon does not read the capability this client advertises, so the number changes no daemon behavior. `cert-status/` and `resume-ipn-bus` are recorded as unwrapped. [COMPATIBILITY-152.md](COMPATIBILITY-152.md) holds the review.
- **Watching works on current daemons.** Tailscale 1.104 and later answer HTTP 400 to a watch whose options include `NotifyRateLimit` (bit 8) or `NotifyInitialNetMap` (bit 3). This was observed on a `tailscaled` v1.104.7 binary; v1.102.2 accepts both. `NotifyWatchOpt.default` includes bit 8. When a watch is rejected with 400 and its options include either bit, the client opens it once more without them and remembers that for later watches. A daemon that accepts the bits receives exactly what the caller asked for. Any other 400 ends the stream instead of being retried.
- **A rejected stream is reported at once.** A streaming response ends where its `Content-Length` or chunk framing says it ends. Today a rejected watch on a kept-open connection is reported only when the daemon closes the connection.
- **`watchIPNBus(reconnect:)` survives a reconnect and an undecodable line**, as its documentation says. Buffer overflow still ends it with `streamOverflow`.
- **New watch options, no new notification fields.** `NotifyWatchOpt` gains named options for upstream bits 12 to 15 (`NotifyPeerChanges`, `NotifyNoNetMap`, `NotifyInitialStatus`, `NotifyPeerPatches`), which both v1.102.2 and v1.104.7 accept. Upstream removed `Notify.NetMap` in 1.104. `IPNNotify` does not model the fields that replace it in this release, because no capture from a logged-in 1.104 daemon exists yet. A notification that carries only those fields still arrives and decodes.
- **How the sample learns that peers changed.** It subscribes with initial state, peer changes, and no-netmap, and treats every notification, reconnect, and state gap as a reason to re-read `status()`, debounced. It does not interpret notification payloads to track peers. That holds on daemons before and after the 1.104 change.
- **API baseline.** `Scripts/check-api-baseline.sh` compares against `v1.0.0` with an empty allowlist. The 1.0 symbol freeze check already accepts additions.
- **A reconnecting watcher rediscovers the daemon.** `watchIPNBus` applies the same credential recovery when it reconnects as when it first connects, for automatically discovered endpoints only. This is a library correction with its own changed-port and changed-token test, so the sample does not carry recovery logic that every other consumer would need too.
- **The sample is a SwiftPM package** under `Examples/PeerDiagnostics`, launched with `swift run`, with its view model in a testable library target. No Xcode project file. It builds with Swift 6.1 and declares the library's macOS 13 minimum, using only APIs available there. Documentation snippets that quote it are checked by `Scripts/check-recipe-snippets.py`, extended to read that package.
- **Claims match measurements.** `SOAK-VERIFICATION.md`, `ADOPTION.md`, and the 1.0.0 release record state only what was run. Where a document asserts a soak run or a commit-signing rate that no artifact supports, rewrite it to the measured result.

## What blocks the tag

Each item is a command or run that passes or fails on the candidate SHA. The candidate is the merged release-preparation commit on `main`. Nothing lands after it. All nine results for that exact SHA go in the release pull request, since a file in the tree cannot name the commit that contains it. `Documentation/releases/1.1.0.md` holds the earlier qualification runs, each labeled with the SHA it ran on, and links to that pull request.

1. `swift test` passes, including path classification from a captured disco reply and the full-field regression for `isDirect`.
2. `./Scripts/check-api-baseline.sh` passes against `v1.0.0` with an empty allowlist.
3. `swift test --package-path Examples/PeerDiagnostics` passes and `swift build --package-path Examples/PeerDiagnostics` succeeds in hosted macOS CI.
4. `All Required Checks` succeeds on the candidate SHA in the hosted [CI workflow](../.github/workflows/ci.yml).
5. The self-hosted [Integration workflow](../.github/workflows/integration.yml) completes successfully on the same SHA. A cancelled run does not count.
6. A consumer in an empty directory resolves the candidate by SHA from GitHub and builds against `TailscaleClient` and `TailscaleClientMocks` with public imports.
7. One standalone-Tailscale Mac, with discovery overrides cleared, reads status, pings an online remote peer, and receives an initial watch notification. The classification of that captured reply equals the official CLI's for the same fields.
8. `./Scripts/check-release-consistency.sh v1.1.0` passes on the prepared commit.
9. Against disposable, never-logged-in `tailscaled` v1.102.2 and v1.104.7 started by `Scripts/disposable-tailscaled.sh`, `tailscale-swift watch` with default options and the sample's own subscription each open and print an initial notification.

Everything else in this plan is recorded as verified, failed, or untested with its scope, and does not hold the tag: the remaining discovery-matrix rows, live daemon restart and profile switching, the agent trial, pilot feedback, and the post-tag Swift Package Index and Homebrew checks.

## Out of scope

Taildrop, Taildrive, Tailnet Lock, Linux qualification, a library-level status snapshot sequence, a ping retry helper, and outreach messages. New ideas found during the work go to [ROADMAP.md](../ROADMAP.md).

## Where the work happens

One branch and pull request per row below, each based on `main` in its own worktree at `~/dev/swift-tailscale-client-<topic>`, merged with a merge commit after a Codex review. The release-preparation commit is last; the maintainer tags it.

## Implementation order

| Change | Ready for the next step when |
|---|---|
| ~~Reconcile claims~~ | Merged in #47. |
| ~~Re-pin upstream~~ | Merged in #49. |
| ~~Examples build from any folder name~~ | Merged in #50. |
| ~~Ping path API and CLI output~~ | Merged in #51. |
| ~~Watch streams survive reconnects and rediscover~~ | Merged in #48; loopback failures classified so watches rediscover in #60. |
| ~~Rejected streams are reported at once~~ | Merged in #53. |
| ~~Watch options that current daemons accept~~ | Merged in #54; quiet loopback watches stay open in #58. |
| ~~The self-hosted integration lane completes~~ | Merged in #52. |
| ~~Endpoint manifest evidence~~ | Merged in #56. |
| ~~Deliver the SwiftUI example~~ | Merged in #55 and #59. |
| Qualify the candidate | Run the hosted checks, independent consumer build, and real-daemon trials below. Finish source, website, and agent docs in the same release. Record every result in `Documentation/releases/1.1.0.md` with the SHA it ran on. |
| Prepare the release commit | Changelog section, `packageVersion`, documented pins, tested daemon versions, and limitations agree. After the merge, all nine items under "What blocks the tag" pass on the merged commit and are recorded in the release pull request. |

## Test acceptance

| Layer | Exercise | Passing result |
|---|---|---|
| Model and wire decoding | Direct endpoint, peer relay, DERP, absent/empty fields, older replies without `PeerRelay`, unknown extra fields, error replies, and conflicting fields. Include a DERP ID with no region code. | Nonempty peer relay takes precedence over DERP, then a reported direct endpoint. A missing path stays unknown. An error never appears as a successful measurement. The same captured input yields the same classification on replay. |
| CLI and existing callers | Run human and `--json` output against a scripted daemon. Compile a consumer using the 1.0 ping initializer, raw properties, and helpers. | Human output distinguishes the three known paths. Existing JSON keys and array shape remain readable by a 1.0 consumer. The API baseline check passes for the library and mocks. |
| Sample state and lifecycle | Script initial status, empty peer list, successful ping, failure, a slow result after the user selects another peer, disconnect, stream gap, reconnect, profile change, and cancellation. | Fixture mode needs no daemon or permission. A late response cannot overwrite the new selection. Old data displays as stale or clears. A fresh status read restores the current peers after a gap. Closing and reopening the sample leaves one watcher. |
| External consumption | From a clean directory, resolve the candidate by SHA in a small SwiftPM or Xcode consumer using public imports. Run the documented mock example and launch the SwiftUI sample. Repeat resolution by tag after publication. | The copyable instructions work without a path dependency, private imports, or prior checkout state. Save the resolved revision, commands, and results. |
| Hosted regression checks | Run the macOS unit suite with coverage, the Thread Sanitizer suite, strict formatting, DocC checks, API baseline, recipe builds/tests, and iOS, tvOS, and watchOS simulator builds. | `All Required Checks` passes on the release SHA. Library line coverage meets the existing 85% floor. Preserve unit and sanitizer reports and their logs. Review each skip against the existing allowlist. Apple mobile platforms remain build-only and Linux remains unqualified. [CI workflow](../.github/workflows/ci.yml) |

### Real-daemon integration

The current self-hosted job runs `TAILSCALE_INTEGRATION=1 swift test --filter TailscaleClientIntegrationTests` and StatusDemo after shell discovery supplies the endpoint. Keep that coverage. Add a separate native-discovery step or record an equivalent manual run on the same candidate. The live workflow runs independently of `All Required Checks`. Record both run links. [Integration workflow](../.github/workflows/integration.yml)

1. **First launch.** Use a Mac with standalone Tailscale running and an online second node. In a fresh process clear every discovery override before launching the candidate. For the existing StatusDemo, the following command exercises the library's default configuration. Repeat the clean-environment launch with Peer Diagnostics and explicitly select live mode.

   ```sh
   (
     for v in $(env | grep -E '^(TAILSCALE|TS)_' | cut -d= -f1); do unset "$v"; done
     swift run --package-path Examples/StatusDemo StatusDemo
   )
   ```

   Discovery reads every `TAILSCALE_` variable and its `TS_` alias, so the loop clears both prefixes. Use the same loop for Peer Diagnostics and any native-discovery CI step.

2. **Peer and watch.** Read status, select the online remote peer, obtain a successful ping and consume an initial watch notification with a bounded timeout. Compare status identity and ping interpretation with the official client on the same Mac. Consecutive pings can change routes. Use the fields from the same captured reply for an exact classification comparison. Save the observed path and daemon version. Label other path types as fixture-tested until observed live. A self-ping, a skipped peer test, or an empty tailnet leaves this trial open.
3. **Recovery.** Exercise disconnect, stream gap, reconnect, and profile change deterministically in the sample tests. Run them live only on a disposable installation: interrupt and restore the daemon connection, then switch profiles if available, and verify the sample marks the old result stale, rediscovers the daemon, refreshes peers, and cannot attach an old result to a new profile. A Mac whose Tailscale connection other work depends on is not disposable, so record those live transitions as untested there. Keep the shared real-tailnet CI lane read-only and leave its write-test flag unset.
4. **Discovery matrix.** Record a row for each combination of standalone, App Store, or Unix-socket daemon and sandboxed or unsandboxed caller. For each attempt record macOS, Swift and daemon versions, signing/entitlements as applicable, opt-in setting, prompt observed, status/peer/watch outcomes, and recovery after denial. Use a fresh permission state when claiming first-prompt behavior. Standalone native discovery with a real peer is the minimum live gate. Mark remaining rows untested, failed, or verified with a link. Only advertise successful environments as verified. Redact addresses, peer names, credentials, and proof-file paths in public evidence.

## Documentation and lint acceptance

| Surface | Required change | Verification |
|---|---|---|
| Swift source comments | Write DocC `///` comments on every new public type, case, property, and method. Document precedence, absent fields, error behavior, and what one ping measures. Document parameters, return values, and throws where applicable. Show a compilable usage example and annotate subtle lifecycle choices in the sample. | Review the public API diff against 1.0.0 and read the rendered symbol pages. A reader should be able to predict the result when a reply contains both a relay and an endpoint. |
| Swift and docs lint | Run `swift format lint --strict --recursive Sources Tests` and lint the new sample's source and test directories explicitly. Run model conformance, generated table and recipe snippet checks. Compile the docs recipes and the new sample. | Zero strict lint or DocC diagnostics on the required jobs. Keep DocC's existing abstract coverage floors of 95% for Types, 80% for Members, and 1% for Globals. Review every added symbol individually since aggregate floors can hide missing comments. |
| README, CLI help, and DocC | Add the fixture and live commands, a fixture screenshot, and a short explanation of direct, peer relay, DERP, unknown, and stale. Link the recipe from Getting Started and the DocC overview. Align CLI help, CLI README, and man page with the actual output. Explain App Store opt-in, supported macOS runtime, build-only targets, and limitations of the trial. | Follow both README paths from a fresh checkout. Run the copyable snippets. Invoke CLI help and compare an example result with the documented output. Inspect the rendered article, navigation, image, and links to the actual public symbols. |
| Website | Build strict DocC and the static site with the repository's hosting base path. After merge, check the Pages deployment for the candidate and follow the root redirect through Getting Started to the recipe and symbol pages. After tagging, select **1.1.0** on Swift Package Index and repeat the navigation. | The static preview works before tagging. Pages serves readable content, working internal links, the screenshot, and the current root `llms.txt`. The SPI tag-specific site resolves after indexing. Record both URLs and the revision or version inspected. [Pages workflow](../.github/workflows/docc.yml) · [SPI configuration](../.spi.yml) |
| Integration and agent docs | Update [INTEGRATING.md](INTEGRATING.md) first. Cover dependency, products, fixture and live paths, discovery consent, and ping interpretation. Reconcile [AGENTS.md](../AGENTS.md), [CLAUDE.md](../CLAUDE.md), [Copilot instructions](../.github/copilot-instructions.md), the [Claude integration skill](../.claude/skills/swift-tailscale-client/SKILL.md), and [llms.txt](../llms.txt) with that guide. For example, replace the Copilot adapter's old Serve snapshot guidance with the supported API. A derived ping property uses the existing ping endpoint. | Run version and generated-table checks. From a fresh consumer, give an agent only the published guidance and ask it to display a peer's last ping path and test the unknown case without a daemon. Build and run its result. Success means correct products and symbols, no credentials or subprocess dependency, and a passing mock test. Record the prompt, revision, and any correction needed. |

Run these repository checks from the candidate root. For Markdown, validate relative links and heading fragments in changed guides and open the linked pages in the rendered site. Use the strict DocC command and coverage parser in [CI](../.github/workflows/ci.yml) and the [static hosting build](../.github/workflows/docc.yml) so the local checks match publication. The two public entry points are [GitHub Pages](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/) and the [Swift Package Index documentation selector](https://swiftpackageindex.com/dweekly/swift-tailscale-client/documentation).

```sh
swift format lint --strict --recursive Sources Tests
swift test --enable-code-coverage
swift test --sanitize=thread
swift test --package-path Examples/Recipes
swift build --package-path Examples/StatusDemo
python3 Scripts/check-model-conformance.py
python3 Scripts/check-recipe-snippets.py
python3 Scripts/generate-endpoint-docs.py --check
python3 Scripts/verify-upstream-maturity.py
./Scripts/check-api-baseline.sh
```

## Release decision and handoff

Use one row per run in the release PR so another maintainer can reproduce the decision. For example:

| Candidate SHA | Check and environment | Expected and observed result | Verdict and evidence |
|---|---|---|---|
| _full commit_ | _Standalone first launch, macOS / Swift / daemon versions, caller sandbox status_ | _Expected status, remote ping, initial watch; record each observed outcome and any prompt_ | _Pass, fail, or untested; link the sanitized log or CI run_ |

- **Before tagging.** The release owner records the candidate SHA, hosted CI run, separate live run, discovery matrix, fixture provenance, consumer smoke test, agent trial, and Pages deployment in the release PR. For each item record pass, fail, or untested with scope and reason. Fix failures on the promised paths and rerun affected checks on the final SHA. Keep the tag pending for a broken clean install, wrong path classification, stale data displayed as current, missing mandatory live results, or documentation that cannot reproduce the example.
- **Prepare and publish.** Update the changelog, package version, documented pins, tested daemon versions, limitations, and release notes together. Run `./Scripts/check-release-consistency.sh v1.1.0` on the prepared commit. Follow the existing annotated-tag workflow. Verify the release contains the universal macOS CLI, checksums, and the validated exact-commit release evidence. Keep links to live and manual evidence alongside the automated reports. [Release workflow](../.github/workflows/release.yml)
- **Verify distribution.** Resolve 1.1.0 in a new consumer, run the tagged sample, check both documentation sites, then update and smoke-test the Homebrew tap. If indexing is delayed, keep that publication check open. For a published regression, follow the patch procedure and preserve the tag. [Release procedure](RELEASING.md) · [Homebrew instructions](HOMEBREW.md)
- **Developer feedback.** Give pilot developers the candidate SHA before release and the tag afterward. Collect first useful result, time to reach it, and the first confusing step. Track reproducible failures through a fix and retest. Review trials and independent app adoption after a month. External uptake informs the next release and carries no pre-tag quota. [Pilot plan](../ROADMAP.md#get-it-into-developers-hands)
