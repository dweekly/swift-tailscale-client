# Documentation

Project documentation for swift-tailscale-client. The [root README](../README.md) indexes the documents outside this folder. The DocC articles listed at the end are published to the [documentation site](https://dweekly.github.io/swift-tailscale-client/documentation/tailscaleclient/).

## Using the package

- [Integrating swift-tailscale-client](INTEGRATING.md): the canonical integration guide for people and coding agents: choosing this package, adding the dependency, the sample app, core usage, upgrading from 1.0, gotchas, endpoint quick reference, and testing with mocks. (updated 2026-11-22; update when: the public API changes, or a new gotcha is found)
- [LocalAPI coverage](LOCALAPI-COVERAGE.md): every LocalAPI endpoint and this package's position on it (implemented, planned, experimental, unsupported), generated from `endpoints.json`. (updated 2026-11-21; update when: `endpoints.json` changes, by regenerating the marked tables with `Scripts/generate-endpoint-docs.py`, or a release changes its hand-maintained version line)
- [Support policy](SUPPORT.md): supported Swift toolchains, operating systems, daemon versions, installation types and discovery, the permission model, redaction policy, and the maintenance lifecycle. (updated 2026-11-21; update when: a platform, toolchain, or daemon floor changes, or a release changes the support scope)
- [Adoption brief](ADOPTION.md): technical evaluation for teams deciding whether to adopt the package: use cases, architecture, the guarantees it makes, compatibility evidence, known limits, and maintenance burden. (updated 2026-11-21; update when: a release changes capabilities, scope, or known limits)

## Working on the package

- [Testing](TESTING.md): the test layers (fixtures, unit, integration, hermetic Headscale lanes), how to run each, fixture capture, write-test gating, and the allowed skips. (updated 2026-11-21; update when: a test lane, gate, or fixture process changes)
- [Releasing](RELEASING.md): versioning, tagging, CHANGELOG discipline, pre-release gates, the release workflow, publication checks, and the patch protocol. (updated 2026-11-22; update when: the release workflow, a gate, or a distribution channel changes)
- [Homebrew](HOMEBREW.md): the `dweekly/homebrew-tap` formula, its per-release update, and the formula template. (updated 2026-11-22; update when: the formula's build or install steps change, or bottles or binaries are adopted)
- [Conformance](CONFORMANCE.md): how decoding is checked against upstream Go behavior: the three test tiers, six conformance surfaces, normalization rules, the wire error mapping, and fault injection. (updated 2026-11-21; update when: a conformance tier is added or the harness changes)
- [Soak verification](SOAK-VERIFICATION.md): the long-running streaming soak protocol, its harness and verdict rules, and the runs measured so far (the 1-hour and 24-hour soaks have not been run). (updated 2026-11-21; update when: a soak is run, or its harness or criteria change)
- [Capability 148 review](COMPATIBILITY-148.md): the upstream review behind raising the default `Tailscale-Cap` from 144 to 148. (updated 2026-09-21; update when: never; superseded by later capability reviews, kept as the record)
- [Capability 152 review](COMPATIBILITY-152.md): the upstream review and compatibility evidence behind raising the default `Tailscale-Cap` from 148 to 152. (updated 2026-11-21; update when: the capability is re-pinned again, which adds a new review rather than editing this one)

## Releases

- [1.1.0 release plan](PLAN-1.1.0.md): what 1.1.0 set out to build (ping paths, Peer Diagnostics, watches on current daemons), its tag-blocking checks, and test acceptance. (updated 2026-11-22; update when: never; 1.1.0 has shipped, and the next release gets its own plan)
- [1.1.0 release record](releases/1.1.0.md): what was run to qualify 1.1.0, on which commits, with results, what remains untested, and the checks after tagging. (updated 2026-11-22; update when: a post-tag check such as Swift Package Index indexing completes)
- [1.0 implementation plan](PLAN-1.0.md): the 1.0 plan as written, with a status header saying what shipped and which requirements were deferred. (updated 2026-11-21; update when: never; historical)
- [1.0 contract decisions](DECISIONS-1.0.md): the seven contract decisions settled before 1.0: Serve write concurrency, streaming framing and cancellation, monitoring and bounded buffers, discovery, experimental API policy, netcheck scope, and supported environments. (updated 2026-09-20; update when: a 1.0 contract decision is reversed in a major release)
- [1.0.0 release record](releases/1.0.0.md): the qualification evidence for 1.0.0 and the NWX adapter smoke test. (updated 2026-11-21; update when: never; historical)
- [Consumer validation](CONSUMER-VALIDATION.md): the 1.0 consumer archetypes, the ledger of resolved integration friction, and the in-tree consumer suites. (updated 2026-11-21; update when: a new consumer archetype or friction point is recorded)
- [Consumer evaluation report](CONSUMER-EVALUATION-REPORT.md): results of the 1.0 in-tree consumer simulations and the one real-consumer smoke test. (updated 2026-11-21; update when: a real consumer's evaluation is added)
- [External review record](EXTERNAL-REVIEW.md): the status of independent technical review of the package; none has been conducted yet. (updated 2026-11-21; update when: an independent review starts or reports)

### 1.0 build history

Specifications and reports from the 1.0 implementation, kept as the record. Test code cites the feature IDs in the project specification.

- [1.0 project specification](1.0/PROJECT.md): the 1.0 architecture, module boundaries, the 36 inventoried features (FEAT-01 to FEAT-36), and the milestone tracks. (updated 2026-09-20; update when: never; historical)
- [1.0 E2E test specification](1.0/TEST_INFRA.md): the 1.0 end-to-end test philosophy and the four test tiers traced to those features. (updated 2026-09-20; update when: never; historical)
- [1.0 test readiness report](1.0/TEST_READY.md): the September 2026 report that the tiered E2E suite was implemented and passing. (updated 2026-09-20; update when: never; historical)

## DocC article sources

These are the sources of the articles on the documentation site, under `Sources/TailscaleClient/TailscaleClient.docc/`.

- [Overview](../Sources/TailscaleClient/TailscaleClient.docc/Overview.md): the module landing page: what the package is, and the topic groups that organize every article and symbol. (updated 2026-11-21; update when: an article or public symbol group is added or removed)
- [Getting Started](../Sources/TailscaleClient/TailscaleClient.docc/GettingStarted.md): adding the dependency, connecting to a running daemon, and the first queries. (updated 2026-11-21; update when: the dependency pin or first-run steps change)
- [Discovery & Permissions](../Sources/TailscaleClient/TailscaleClient.docc/DiscoveryAndPermissions.md): how the client finds the LocalAPI on each installation type, and the one macOS case that prompts for permission. (updated 2026-09-20; update when: a discovery method or permission behavior changes)
- [Error Handling](../Sources/TailscaleClient/TailscaleClient.docc/ErrorHandling.md): each `TailscaleClientError` case, what it means, and how to respond. (updated 2026-09-20; update when: an error case is added or its meaning changes)
- [Streaming Guide](../Sources/TailscaleClient/TailscaleClient.docc/Streaming.md): consuming IPN bus notifications as async streams, with bounds, gaps, and reconnects. (updated 2026-09-20; update when: watch options, stream bounds, or reconnect behavior change)
- [Writing Safely](../Sources/TailscaleClient/TailscaleClient.docc/WritingSafely.md): changing daemon configuration without clobbering the user's settings: masked preference patches and ETag-checked replacement. (updated 2026-09-20; update when: a write API or its concurrency rule changes)
- [Serve, Funnel & Certificates](../Sources/TailscaleClient/TailscaleClient.docc/ServeAndFunnel.md): reading and changing what a node serves, with optimistic concurrency, and fetching certificates. (updated 2026-09-20; update when: the Serve or certificate API changes)
- [The Login Flow](../Sources/TailscaleClient/TailscaleClient.docc/LoginFlow.md): driving interactive login from an app through the IPN bus. (updated 2026-09-20; update when: the login API or upstream login sequence changes)
- [Version Compatibility](../Sources/TailscaleClient/TailscaleClient.docc/VersionCompatibility.md): how the package behaves across daemon versions, and what to do when the daemon is older or newer than expected. (updated 2026-11-21; update when: the capability pin or a version-dependent behavior changes)
- [Stability Tiers](../Sources/TailscaleClient/TailscaleClient.docc/StabilityTiers.md): which APIs are stable under SemVer and which experimental ones can change. (updated 2026-09-20; update when: an API moves between tiers)
- [Migrating from 0.12.x to 1.0](../Sources/TailscaleClient/TailscaleClient.docc/MigrationFrom012.md): the 1.0 breaking changes and how to update 0.12.x code. (updated 2026-09-20; update when: never; historical, for 0.12.x users)
- [Recipe: Show How a Ping Reached a Peer](../Sources/TailscaleClient/TailscaleClient.docc/RecipePeerDiagnostics.md): classifying ping paths (direct, peer relay, DERP) with the Peer Diagnostics sample. (updated 2026-11-21; update when: `PingPath` or the sample changes)
- [Recipe: Monitor Peer and Connection Changes](../Sources/TailscaleClient/TailscaleClient.docc/RecipeMonitoring.md): replacing status polling with one long-lived IPN bus watch. (updated 2026-11-21; update when: recommended watch options change)
- [Recipe: Menu-Bar Status App](../Sources/TailscaleClient/TailscaleClient.docc/RecipeMenuBar.md): a macOS `MenuBarExtra` showing live Tailscale state. (updated 2026-08-02; update when: its compiled snippets in `Examples/Recipes` change)
- [Recipe: Select or Disable an Exit Node](../Sources/TailscaleClient/TailscaleClient.docc/RecipeExitNode.md): listing exit-node candidates and applying a choice with a masked write. (updated 2026-08-02; update when: its compiled snippets in `Examples/Recipes` change)
- [Recipe: Configure Serve and Retrieve Certificates](../Sources/TailscaleClient/TailscaleClient.docc/RecipeServe.md): adding a TCP forward with ETag-safe concurrency and fetching the node's TLS certificate. (updated 2026-09-20; update when: its compiled snippets in `Examples/Recipes` change)
- [Recipe: Test with Mocks](../Sources/TailscaleClient/TailscaleClient.docc/RecipeTesting.md): deterministic tests of a Tailscale integration with `TailscaleClientMocks`. (updated 2026-08-02; update when: `MockTransport` or its snippets change)
