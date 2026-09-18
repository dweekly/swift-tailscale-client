# 1.0 implementation and release plan

Status: proposed implementation sequence, 2026-09-17. No implementation work is marked complete by this plan.

This package should reach 1.0 with a supportable Swift API for observing and controlling an existing Tailscale daemon. The release must demonstrate safe configuration updates, bounded resource use, predictable cancellation and recovery, and compatibility with explicitly supported daemon versions and installation types.

`swift-tailscale-client` is unofficial and is not endorsed by Tailscale Inc. Being suitable for adoption and being adopted by Tailscale are separate outcomes. Technical release gates below are under this project's control; Tailscale's participation, endorsement, or ownership is not a prerequisite for releasing.

This is the detailed execution plan linked from [ROADMAP.md](../ROADMAP.md). Endpoint facts remain authoritative in [endpoints.json](endpoints.json); integration instructions remain in [INTEGRATING.md](INTEGRATING.md). Update [TESTING.md](TESTING.md) and [RELEASING.md](RELEASING.md) as the corresponding implementation lands, rather than duplicating their operating instructions here.

## 1. Starting point and scope

The readiness review found valuable foundations already in place: Swift 6 concurrency checking, injectable transports, public mocks, an upstream-pinned endpoint inventory, tolerant models, secret-redaction tests, a fault-injection socket server, Headscale integration infrastructure, strict DocC builds, and weekly upstream-drift detection.

Review evidence on 2026-09-17:

- Local `swift test`: 357 tests executed, 45 skipped, zero failures. This was not a live-daemon integration run or a fresh coverage measurement.
- Endpoint-document generation, model conformance, release consistency, and compiled-recipe consistency checks passed.
- A scratch program using repository source demonstrated loss of unknown Serve fields at both the root and nested handler levels, and acceptance of a complete HTTP header exceeding the nominal 64 KiB limit.
- Source inspection found that the Unix unary path does not validate Content-Length or require chunk-decoder completion before returning, and that streaming buffers are unbounded.
- The Linux daemon matrix workflow currently runs nightly or manually, not on every PR. macOS integration setup can inject externally discovered credentials, so its success does not establish native library discovery for every installation flavor.

Existing tests and tools are starting points, not proof that the new gates are satisfied. Each work item below requires committed regression tests and reproducible evidence.

### Scope boundaries

- Keep status, identity, preferences, lifecycle, Serve/Funnel, and monitoring as the primary use cases.
- Keep Taildrop, Taildrive, Tailnet Lock, duplex dial APIs, and bug-report recording handles additive post-1.0 work.
- Do not broaden platform claims: macOS and Linux have daemon runtime support; iOS/tvOS/watchOS remain build-only consumers of shared code/models.
- Make no ABI-stability commitment unless a separate binary-distribution requirement justifies one. The default 1.0 promise is Swift source compatibility and documented behavior within the supported environment matrix.
- Avoid a broad rewrite. Any dependency or architectural replacement needs a bounded comparison spike and a migration path for downstream transports and mocks.

## 2. Milestones and implementation order

Milestones are exit criteria, not calendar promises. Ship intermediate 0.x releases when useful; choose version numbers when cutting those releases.

| Milestone | Work items | Exit evidence |
|---|---|---|
| M0 — Establish the contract | W0; start W8 outreach preparation | Recorded design decisions, explicit support policy draft, regression reproductions |
| M1 — Reliability | W1, W2, W3 | Safe writes, framing and cancellation tests, bounded streaming and recovery |
| M2 — Compatibility | W4, W5, W6 | Native discovery matrix, versioned fixtures, exact-commit integration evidence |
| M3 — Freeze candidate | W7, W8 | Public API baseline, complete docs, consumer migrations, maintenance policy |
| M4 — Release candidate and 1.0 | W9 | Soak report, all required checks on release commit, complete release artifacts |

Dependencies:

- W0 settles public contract direction before implementing breaking API changes.
- W1 can proceed independently of W2 once the snapshot design is recorded.
- W2 supplies response metadata and cancellation behavior required by W3.
- W4 supplies credential refresh and endpoint resolution used by W3 recovery. Implement ordinary reconnect first; integrate rediscovery after W4.
- W5 fixture/harness work can begin early. W6 consumes its evidence format and tests.
- W7 may audit early, but freezes only after W1–W6 public API changes settle.
- W8 adoption preparation starts early and consumer migration continues through M3.
- W9 requires M1–M3 completion. No endpoint expansion should delay that sequence.

## 3. Work items

### W0 — Record the public contract decisions

**Deliverable:** a short design-decision record, checked into `Documentation/`, with proposed signatures, downstream usage examples, alternatives, and migration implications. Completed in [`Documentation/DECISIONS-1.0.md`](DECISIONS-1.0.md) and [`Documentation/SUPPORT.md`](SUPPORT.md). Illustrative names in this plan are not approved API signatures.

Decisions to settle:

1. **Serve writes:** separate editable configuration from the daemon-provided concurrency snapshot; default to conditional updates. Provide an explicitly named unconditional replacement operation for intentional replacement.
2. **Streaming transport:** expose the response status and headers before body iteration, plus an explicit lifetime/cancellation contract. Keep HTTP framing internal where practical; do not design an unused universal networking abstraction.
3. **Monitoring:** expose connection lifecycle/gap information separately from sparse daemon notifications, with a defined bounded-buffer policy.
4. **Discovery:** distinguish automatically resolved connections from explicitly pinned endpoint/token configurations. Only the former rediscover credentials automatically.
5. **Experimental API:** recommended default is source compatibility for every public symbol shipped in the same versioned package, while experimental behavior/availability may track upstream. If breaking experimental APIs independently is necessary, use a separately versioned package. A second target in the same package does not provide independent versioning.
6. **Diagnostics scope:** decide whether STUN/netcheck stays in the core product or moves to an optional diagnostics product. Extract only if the maintenance/dependency boundary materially improves. Clarify its limitations either way; it is not a full substitute for upstream netcheck.
7. **Supported environments:** establish concrete daemon versions, Swift toolchains, operating systems, installation flavors, and permission assumptions. Select the daemon floor from successful tests; do not silently convert the existing `1.96.4` lane into a permanent support promise.

**Acceptance:** compile small consumer sketches for the proposed API; record the chosen defaults and rejected alternatives; identify all breaking migrations before the freeze. Consumers must be able to inject transports and create fixtures without relying on internal details.

### W1 — Safe configuration updates

**Primary files:** `Models/ServeConfig.swift`, `ServeAPI.swift`, `Models/PrefsResponse.swift`, `Models/MaskedPrefs.swift`, `Models/DaemonControl.swift`, relevant model and write tests.

Implementation:

- Preserve unknown JSON fields recursively throughout Serve replacement-write models, including nested TCP/Web/service/foreground configuration. Known-field edits must not erase unrelated unknown fields.
- Choose a representation that preserves JSON numeric values without silently rounding large unknown integers through `Double`. Existing `JSONValue` is useful, but its numeric fallbacks must be assessed before claiming lossless preservation.
- Define known/unknown key collision handling and omitted-versus-null behavior. Reject malformed known fields instead of silently converting them into destructive defaults; include invalid port-map keys in this audit.
- Introduce a snapshot whose concurrency token comes from a read and cannot accidentally disappear during an edit. Associate it with the relevant target/configuration scope so a snapshot is not unintentionally reused against a different daemon.
- Fail conditional updates when no usable ETag is available; provide a clearly named unconditional operation rather than silently weakening the guarantee. Document older-daemon behavior.
- Keep preference changes patch-based through `MaskedPrefs`. Inventory every API that can replace a complete preferences object. Keep `StartOptions.UpdatePrefs` internal unless preference preservation is proven; full Prefs preservation is not mandatory if no public fetched-snapshot replacement path is exposed.
- Keep fresh-profile initialization clearly distinct from updates to an existing configured profile. Never automatically retry a mutation after an ambiguous transport failure.

**Acceptance tests:**

- [ ] Decode → edit one known field → encode preserves root and nested unknown fields, nulls, arrays, large numbers, and unrelated handlers.
- [ ] Missing/null/empty ETags cannot produce an accidental unconditional update.
- [ ] Two concurrent writers produce a typed stale-write error; explicit replacement is separately tested.
- [ ] A snapshot for another target is rejected or the API otherwise makes target scope unambiguous.
- [ ] Masked preference updates preserve all settings not selected for change.
- [ ] Apply → verify → restore tests pass against disposable supported daemons; fixture capture records the observed ETag behavior.
- [ ] README, Serve recipe, compiled examples, and write-safety docs use the safe default API.

**Done when:** the documented read-modify-write recipe preserves daemon fields that this release does not understand and detects concurrent changes. Semantic preservation is required; byte-for-byte JSON formatting is not.

### W2 — HTTP framing, deadlines, and resource ownership

**Primary files:** `Transport/UnixSocketTransport.swift`, `HTTPWireFormat.swift`, `ChunkedTransferDecoder.swift`, `TailscaleTransport.swift`, `FaultUnixServer.swift`, parser/fault tests.

First run a bounded transport spike: compare hardening the current implementation with a maintained Swift networking implementation. Evaluate macOS/Linux parity, Unix sockets, streaming, cancellation, minimum Swift version, dependency footprint, memory, and downstream transport compatibility. Retain the existing implementation if the alternative does not clearly improve the result.

Required behavior regardless of implementation:

- Parse headers incrementally; enforce the header limit even when the terminator is already present in the input buffer.
- Respect message framing: Content-Length, chunk termination/trailers, responses without a body, and permitted EOF framing. Reject truncated framed messages and conflicting framing; explicitly document supported HTTP behavior rather than guessing from EOF.
- Enforce configurable response and line-size limits before unbounded accumulation. Choose documented finite defaults from large-tailnet fixtures and stress measurements, with an explicit override for legitimate larger payloads.
- Make connect, write, header-read, and body-read cancellation cooperative. Blocking POSIX operations must not occupy Swift's cooperative executor indefinitely; choose an appropriate nonblocking/evented or explicitly managed blocking execution strategy.
- Define timeout versus caller-cancellation errors consistently across Unix and URLSession transports. A task-group timeout is insufficient if its losing operation cannot terminate.
- Close each socket/body resource exactly once on success, failure, cancellation, partial setup, and consumer termination. Prevent descriptor-reuse races in any cancellation-close design.
- Validate request paths, methods, and headers before serializing raw HTTP. Encode user-supplied path segments consistently across transports and reject CR/LF injection.
- Exercise URLSession behavior too: redirect/authentication handling, cancellation, cache/proxy assumptions, and status/header parity. Use a dedicated local fixture server or controlled URL protocol as appropriate.

**Acceptance tests:**

- [ ] Every split point of representative HTTP heads/chunks succeeds identically; truncated Content-Length/chunked messages fail with typed framing errors even if the available JSON is syntactically complete.
- [ ] Oversized headers, bodies, and lines fail at the configured bound, with no sensitive payload in the diagnostic message.
- [ ] Cancellation and deadline tests cover blocked connect, blocked write, header wait, body wait, and stream consumption. Use an independent server watchdog; target completion within one second after cancellation with documented CI scheduling tolerance.
- [ ] At least 100 connect/cancel/failure cycles return owned descriptor/task counts to baseline. Establish platform-aware tolerances rather than hiding sustained leaks.
- [ ] Seeded malformed-input/property tests run in PR CI; longer fuzz runs have a bounded scheduled budget and retain failing seeds as regression cases.
- [ ] TSan and relevant sanitizer runs are clean; supported Unix and loopback paths have contract tests.

**Done when:** resource bounds and cancellation are demonstrated through the real transport, not only by cooperative mocks.

### W3 — Bounded, observable streaming and recovery

**Primary files:** `TailscaleClient.watchIPNBus`, transport streaming API, `Experimental.swift`, `Models/IPNNotify.swift`, `TailscaleClientMocks`, streaming tests and monitoring recipes.

Implementation:

- Share unary and streaming setup logic for audit headers, daemon-version observation, and typed status errors. Bound and redact error-body handling.
- Bound all queues, including the transport-to-decoder queue and the decoder-to-consumer queue. Measure both event count and retained bytes; one large NetMap can defeat an event-count-only bound.
- Recommended initial overflow behavior: fail explicitly with an overflow/gap error. A consumer can then re-establish its state. Do not silently use `bufferingNewest(1)` for sparse notifications, and do not promise lossless delivery across disconnects.
- Provide lifecycle events or a reporting interface for connected, disconnected, retrying, and state-invalidated/gap conditions. Decide in W0 whether this is a new stream element type or a separate observation API.
- Specify how malformed lines affect freshness. Continue reporting/skipping malformed JSON if retained as the default, but mark state as potentially stale when an update was lost. Raw lines stay an explicit sensitive-data surface.
- Preserve caller watch options across reconnects. Document exactly which requested initial fields rebuild state; receiving any notification does not prove a complete snapshot. Do not claim atomicity between a separate `status()` read and watch subscription.
- Add retry classification, capped exponential backoff with jitter, deterministic clock/random injection for tests, and visible exhaustion behavior. Permanent permission/unsupported-endpoint errors should terminate; transient disconnects may retry. Test repeated short successful connections so retries do not become a tight loop.
- Apply W4 rediscovery to automatically resolved connections when appropriate. Never replay a write while recovering a watch connection.
- Define lifetime ownership, including cancellation while opening and consumers that stop iterating while retaining a stream reference. Use an explicit subscription/cancel handle if plain stream termination cannot satisfy the contract.

**Acceptance tests:**

- [ ] Slow consumers and oversized payloads exercise the documented overflow behavior without silent loss or unbounded growth.
- [ ] Unix and loopback streams produce equivalent typed 401/403/404/429 handling where appropriate, version diagnostics, and audit headers.
- [ ] Reconnect reports the gap, preserves options, respects retry policy, and can recover after an automatic endpoint/token changes.
- [ ] Cancellation, early iteration exit, retained references, and failed setup leave no background reader running unintentionally.
- [ ] A one-hour synthetic stream/reconnect soak records queue high-water marks, memory, task/descriptor counts, and latency. Memory plateaus after warm-up; finite configured queue bounds hold.
- [ ] Public mocks script response heads, lifecycle events, errors, overflow, cancellation, and controlled timing; compiled recipes demonstrate freshness handling.

### W4 — Native discovery across macOS installation types

**Primary files:** `Configuration/LocalAPIDiscovery.swift`, `Platform/MacClientInfo.swift`, configuration types, discovery tests, macOS integration workflow.

Implementation:

- Implement the standalone app's `/Library/Tailscale/ipnport` symlink and file-content token mechanism separately from the App Store filename-token mechanism, cross-checking pinned upstream safesocket behavior.
- Keep App Store/TCC-triggering discovery explicitly opt-in. Standalone app discovery must not accidentally require that opt-in merely because both use loopback TCP.
- Preserve explicit environment/configuration precedence. Automatic candidates need bounded liveness/authentication checks and stale-candidate fallback; distinguish not installed, stopped, inaccessible, and invalid credentials in actionable errors.
- Add an asynchronous discovery/connection path for UI clients; avoid blocking the main actor with filesystem/probe waits. Audit synchronous convenience construction and document or revise its cost.
- Refresh automatic credentials after daemon restart, with bounded attempts and single-flight coordination for concurrent callers. Explicitly pinned credentials remain pinned.
- Test permission boundaries without broadening file access or logging token-bearing paths. Retain existing redaction checks and add the new file-content path.

**Acceptance matrix:**

| Installation | Required scenarios |
|---|---|
| macOS standalone daemon / Homebrew | Default/custom socket; stale socket; stopped daemon; inaccessible socket |
| macOS standalone `.pkg` app | Native port/token discovery; unreadable token; stale port; restart and credential rotation |
| macOS App Store app | Opt-in discovery; denied access; stale proof; restart; default path causes no TCC-triggering access |
| Linux daemon | Default/custom socket; operator permissions; daemon restart |

- [ ] Integration runs invoke the library's discovery without endpoint/token environment overrides for each native-discovery case.
- [ ] Explicit-configuration integration remains a separate test; CI shell discovery is not accepted as evidence for library discovery.
- [ ] Signed/sandboxed macOS consumer behavior is documented from an actual spike. Do not claim sandbox support based on an unsandboxed CLI test.
- [ ] Where macOS install-flavor automation is unavailable, retain repeatable manual test steps with exact OS/app/package versions and sanitized results for the release candidate.

### W5 — Compatibility fixtures and behavioral conformance

**Primary files:** `Documentation/endpoints.json`, fixture directories, integration suites, new capture/conformance tools under `Scripts/`.

Implementation:

- Define the supported daemon window with exact numeric versions in release evidence. Use a tested floor and named release versions for blocking lanes; retain latest stable/unstable discovery as drift lanes. A moving track name alone is not release evidence.
- Extend the manifest schema for method-specific permissions/risk and evidence where endpoints combine reads and writes. Distinguish HTTP method, daemon permission requirement, and state mutation: a POST is not automatically a persistent write, and a diagnostic call can still require write permission.
- Replace vague minimum-version claims with verified numeric bounds or explicit unknown/not-guaranteed availability. Do not fabricate historical introduction versions; use typed endpoint-unavailable behavior outside verified availability.
- Inventory supported operations against named tests. Classify evidence as live success, permission denial, absent feature, request contract, or intentionally untested destructive action. A skipped test is not a successful endpoint exercise.
- Add a fixture capture/sanitization tool. Store fixtures by daemon version and include upstream revision, installation/build flavor, capture command, status/headers, package SHA, and sanitization notes. Retain ETags and header structure without retaining credentials or real identities.
- Keep crafted adversarial fixtures clearly labeled as synthetic; they complement real captures.
- Build a small Go-vs-Swift conformance harness pinned to the upstream revision. Initially cover status with/without peers, identity lookup, masked prefs, Serve ETags, and streaming setup/initial fields. Normalize timestamps, map ordering, volatile counters, and secret material; compare equivalent isolated states for writes.
- Use a disposable production-Tailscale environment for a small declared set of control-plane-dependent behaviors that Headscale cannot establish. Select those cases from the evidence inventory, with quotas, cleanup, and non-fork secret handling. Headscale remains the default mutation environment.

**Acceptance:**

- [ ] Supported-version and install-flavor tables are concrete and consistent across manifest, integration guide, DocC, and release evidence.
- [ ] Versioned captures decode across the supported matrix; unknown fields/enums and absent `omitempty` fields have targeted tests.
- [ ] New unexpected skips fail the required lane. Expected omissions have explicit reasons and alternative evidence where possible.
- [ ] Differential tests detect deliberately injected request/decoding mismatches and pass against their pinned reference.
- [ ] Production-only claims have successful disposable-environment evidence, or are narrowed/tiered honestly before the freeze. No write tests run on a personal/live production tailnet.

### W6 — Exact-commit CI and release evidence

**Primary files:** `.github/workflows/ci.yml`, `integration-linux.yml`, `integration.yml`, `release.yml`, test/release documentation, new evidence tooling.

Implementation:

- Make the supported Linux/Headscale matrix reusable and run it on PRs and release candidates. Use exact versions in required lanes. Unstable remains a visible, nonblocking drift signal with triage ownership.
- Preserve the self-hosted macOS fork guard; do not execute untrusted fork code with live-tailnet or privileged runner access. Obtain native macOS evidence on reviewed commits using trusted runners/manual release runs as needed.
- Add a required-check aggregator and verify repository branch protection/rulesets actually require it. Workflow YAML alone does not establish a merge gate.
- Produce machine-readable evidence recording commit SHA, dependency lock hash, Swift/OS/daemon/Headscale versions, installation flavor, feature availability, test counts/skips, and artifact/run links. Upload sanitized logs and retain release evidence beyond short-lived Actions artifacts.
- Gate release publication on required evidence for the exact tag commit, including docs, examples, API compatibility, supported daemon lanes, and platform builds. Reuse successful exact-SHA runs only after validating their required matrix/configuration; do not accept a recent green run on another commit.
- Enforce annotated tags as documented. Build and smoke-test all release assets before publishing the release; use draft staging if needed so partial build failures do not expose an apparently complete release.
- Publish checksum files and suitable artifact provenance. Smoke-test packaged CLI binaries on clean target environments, including Linux runtime dependencies; exercise the Homebrew formula before announcement.
- Keep credentials out of evidence. Pin third-party workflow actions/dependencies to an auditable update strategy and review privileged permissions.

**Acceptance:** deliberately simulate a missing lane, unexpected skip, mismatched SHA, unannotated tag, failed binary build, and failed docs/API check. Each must prevent publication. The full successful rehearsal must produce complete evidence and artifacts without publishing a public 1.0 release.

### W7 — API freeze, documentation, and support policy

**Primary files:** public library/mocks surface, `Package.swift`, examples, DocC, README, integration/testing/releasing guides, `SECURITY.md`, `CONTRIBUTING.md`, agent adapters.

Implementation:

- Audit names against Swift conventions and upstream semantics, remove deprecated `addProfile()`, and migrate examples. Review errors, optionality, mutability, public initializers, identifiers, and methods that can replace or destroy state.
- Finalize W0's experimental compatibility policy and any diagnostics extraction. Avoid exposing low-level types solely to simplify internal tests.
- Establish compiler-supported API/source compatibility checking against a checked-in or reproducibly generated baseline. Test the baseline on the minimum and current supported toolchains, macOS and Linux, and both library products. Include an external consumer implementing a custom transport so protocol breaks are caught.
- Treat added enum cases, protocol requirements, overload ambiguities, actor isolation/Sendable changes, and changed default behavior as compatibility review topics; a symbol-name diff alone is insufficient.
- Complete useful DocC abstracts and topic curation for authored public APIs. Raise the current coverage floors to full authored API coverage; inventory generated/compiler symbols separately rather than adding meaningless comments to satisfy a percentage.
- Update the tutorial and at least two compiled examples to demonstrate new write/stream/discovery contracts. Include migration notes from 0.12.x and an explicit compatibility/support matrix.
- Remove stale future-tense statements from TESTING/RELEASING/ROADMAP. Existing drift automation and Dependabot should be described as shipped. Document actual check triggers and measured guarantees.
- Specify the post-1.0 security patch policy, supported release branches, deprecation policy, and upstream incompatibility response. Keep disclaimers accessible without making every runtime error an advertisement.

**Acceptance:**

- [ ] Public API baseline approved after W1–W6; an intentional source-breaking change fails CI.
- [ ] Minimum/current toolchains, platform builds, examples, mocks, and custom-transport consumer compile.
- [ ] Strict DocC and authored-public-symbol coverage pass; recipes match compiled sources.
- [ ] Stable-versus-experimental behavior, daemon availability, supported environments, and security support are unambiguous and consistent.
- [ ] All user-visible changes have changelog/migration entries; canonical documentation and adapters agree.

### W8 — Consumer validation and upstream adoption preparation

Start this work during M0; don't wait until the API has frozen to discover consumer requirements.

Project-owned deliverables:

- Migrate NWX and recruit a second real consumer maintained independently of this library. The second consumer should exercise a different workflow where feasible, such as configuration/lifecycle management rather than another status demo.
- Record integration friction, missing abstractions, and required internal workarounds. Feed API-breaking needs back before W7. Repository examples alone do not count as independent adoption evidence.
- Obtain external review of the transport, safe writes, discovery, and streaming design. A qualified reviewer need not be a Tailscale employee for the technical release gate.
- Record contribution/provenance policy, whether to use DCO, license/attribution inventory, release ownership, and security triage responsibility. Identify a backup maintainer and rehearse the release checklist with someone other than the primary author.
- Prepare a concise adoption brief: intended use cases, architectural boundary, guarantees, compatibility evidence, known limitations, maintenance burden, and a concrete sample integration.

Tailscale-specific collaboration goals:

- Identify a plausible internal consumer and an engineer who owns the relevant integration boundary. Validate whether LocalAPI is appropriate; do not assume an official Apple GUI would replace its existing integration with this library.
- Request design feedback while changes are still cheap. Offer a bounded integration PR or evaluation branch rather than asking for broad endorsement.
- Discuss package ownership/naming, support responsibilities, upstream change notification, and licensing requirements only against an actual integration proposal.
- Prepare a Community Projects submission as an intermediate discovery channel. Community listing, code review, production use, and repository transfer are distinct outcomes.

**Acceptance for the independent 1.0 release:** two real consumer integrations, one external technical review with blocking findings resolved, and a recorded maintenance/security/release ownership plan. An unanswered request to Tailscale does not hold the release indefinitely or justify claiming endorsement. This plan authorizes preparation, not sending outreach messages or transferring ownership.

### W9 — Release candidate, soak, and publication

Release-candidate scope is fixes and evidence collection. New features requiring API redesign return the candidate to M3.

- Publish an RC after W1–W8 project-owned gates pass. Record the exact SHA and dependency lock state.
- Run a proposed minimum 14-day consumer evaluation period across NWX and the independent consumer, including daemon upgrades/restarts, sleep/wake, network transitions, logout/login in disposable environments, and slow/cancelled watchers.
- Complete the one-hour synthetic stream test plus at least one 24-hour monitoring run. Record environment, event volume, memory/resource behavior, reconnects, and any gaps; don't claim universal performance from a single run.
- Triage defects explicitly: crashes, secret exposure, unintended configuration loss, silent event loss, cancellation hangs, supported-environment failures, and missing required release evidence block 1.0. Cosmetic/nonbreaking follow-ups may be tracked with rationale.
- Re-run affected tests after fixes. Restart the relevant soak after changes to transport/stream/discovery ownership or semantics; editorial-only changes need not restart the consumer clock, but the final commit still needs its required automated checks.
- Rehearse staged publication, asset validation, checksums, formula installation, and versioned documentation. Tag the already-tested final commit; do not add a release-preparation commit after collecting its evidence.
- Publish release notes with exact tested environments, availability limitations, migration guidance, and the deferred endpoint ledger. Verify assets, documentation indexing, and package resolution before announcement.
- Rollback/recovery: never move a published tag. Withdraw misleading release claims or affected assets if necessary, document the issue, and publish a corrected patch release; prepare these procedures before the rehearsal.

## 4. Reviewable PR sequence

Each PR should include relevant regression tests and documentation. Avoid a single transport-and-API rewrite PR.

| PR | Deliverable | Depends on |
|---|---|---|
| 01 | W0 decision record, precise baseline/support draft, reproducible regression cases | This plan |
| 02 | Lossless Serve representation and adversarial round-trip tests | 01 |
| 03 | Conditional snapshot update API, explicit replacement, examples/migration | 02 |
| 04 | Transport spike decision, framing/limits fixes and fault cases | 01 |
| 05 | Connect/write/read cancellation and ownership fixes | 04 |
| 06 | Streaming response metadata and shared error/audit/version contract; mocks | 05 |
| 07 | Bounded streaming, lifecycle/gap reporting, deterministic retry policy | 06 |
| 08 | Native standalone/App Store discovery and async resolution tests | 01 |
| 09 | Credential-refresh recovery, native install-flavor integration evidence | 07, 08 |
| 10 | Versioned capture tooling, evidence schema, endpoint/test inventory | 01; update after 03–09 |
| 11 | Go conformance harness and selected production-control-plane evidence | 10 |
| 12 | Required daemon CI lanes, exact-SHA aggregation, staged release rehearsal | 09–11 |
| 13 | Final public API audit, compatibility gate, support/experimental policy | 03–12 |
| 14 | Complete DocC, consumer migrations, governance, maintenance rehearsal | 13; W8 started earlier |
| 15 | RC evidence, defect closure, 1.0 release preparation | 14 and W9 soak |

Split or combine adjacent PRs when review becomes clearer, preserving the dependencies and exit criteria. Review source-level compatibility changes before publishing another 0.x release so consumers have explicit migration notes.

## 5. Release evidence checklist

Maintain a release record under `Documentation/releases/` when implementation begins; do not fill it with planned results. Assign an owner/reviewer and link a PR plus a test report, fixture set, or run for each completed gate. Generated reports must carry their source commit SHA.

- [ ] **G1 Safe writes:** unknown-field preservation, conditional updates, explicit replacement, disposable-daemon mutation evidence.
- [ ] **G2 Transport:** framing, finite limits, cancellation at every phase, resource ownership, seeded/fuzz regressions.
- [ ] **G3 Monitoring:** bounded queues, explicit gap/overflow behavior, retry classification, cleanup and soak evidence.
- [ ] **G4 Discovery:** native library evidence for each supported install flavor, permissions, restart/credential refresh, sandbox claims.
- [ ] **G5 Compatibility:** exact supported versions/toolchains, endpoint evidence inventory, versioned fixtures, conformance results, controlled skips.
- [ ] **G6 Release gates:** required checks/rulesets, exact-SHA evidence, annotated-tag check, staged artifacts, negative gate rehearsal.
- [ ] **G7 API and docs:** approved compatibility baseline, experimental policy, complete authored API docs, compiled examples, migration guide.
- [ ] **G8 Consumers and maintenance:** two real integrations, external review, backup release owner, security and contribution policy.
- [ ] **G9 RC:** evaluation/soak reports, no open blocking defects, complete tested release commit and distribution rehearsal.

Endpoint inventory and aggregate coverage remain useful guardrails, but cannot substitute for these gates. Keep the existing 85% line-coverage floor and improve meaningful coverage while implementing the failure scenarios above.

## 6. References and authority

- [Official Go LocalAPI client](https://github.com/tailscale/tailscale/blob/main/client/local/local.go): reference for endpoint semantics and maturity. Implementation work must use the immutable revision recorded in `endpoints.json`, not assume moving `main` is the release contract.
- [Upstream Darwin safesocket](https://github.com/tailscale/tailscale/blob/main/safesocket/safesocket_darwin.go): reference for install-specific connection and credential handling; likewise pin the revision used for implementation evidence.
- [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift): embedded-node architecture, distinct from this package's LocalAPI role.
- [Tailscale Community Projects](https://tailscale.com/docs/reference/tailscale-community-projects): community discovery/submission path, not evidence of endorsement.
