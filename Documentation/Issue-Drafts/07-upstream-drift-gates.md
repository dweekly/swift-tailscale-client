Pin wire contracts to upstream and automate LocalAPI and Swift API drift detection

Why

LocalAPI JSON shapes, endpoint registration, feature gates, and maturity annotations move with Tailscale development.

Documentation/endpoints.json is now a strong project-level source of truth. It should also record upstream provenance and drive compatibility evidence.

Current manifest:

https://github.com/dweekly/swift-tailscale-client/blob/main/Documentation/endpoints.json

Tailscale publishes stable clients roughly every four weeks and unstable clients every few days:

https://tailscale.com/docs/reference/tailscale-client-versions

Hand-maintaining wire models without mechanical comparison will eventually drift, however conscientious the maintainers are. Humans remain excellent at judgment and merely adequate at remembering that one Go field changed capitalization on a Tuesday.

Scope

Record upstream provenance

Record alongside the endpoint manifest:

* Upstream Tailscale commit.
* Upstream released version, where applicable.
* Capability version.
* Verification date.
* Relevant Go methods and types.

Each generated or hand-maintained wire type should be traceable to an upstream source revision.

Generate or validate wire contracts

Where practical:

* Generate internal Swift wire structs from selected Go definitions.
* Keep deliberately designed public Swift façades separate from generated wire types.
* Map between wire and public layers explicitly.

Where generation is impractical:

* Generate canonical JSON requests and responses from upstream Go types.
* Decode and encode those fixtures in Swift.
* Cover optional fields, omitted fields, unknown fields, numeric map keys, enum evolution, zero values, and custom marshaling behavior.

Scheduled upstream drift check

Add a scheduled workflow that compares the pinned snapshot with Tailscale main and reports:

* Endpoint additions and removals.
* HTTP method or expected-status changes.
* Feature-gate changes.
* Stable/unstable annotation changes.
* Relevant Go struct changes.
* Capability-version changes.
* Newly stable methods absent from the Swift client.

The workflow should open an actionable report or proposed PR. It must not silently update generated code and claim compatibility.

Daemon compatibility ledger

Retain and expand the current lanes:

* Current stable.
* Previous stable.
* Unstable.

Publish or generate a compatibility ledger showing:

* Tested daemon versions.
* Endpoint availability.
* Known optional-feature differences.
* Preview endpoint failures.
* Capability advertised by the Swift client.

Public Swift API drift

Before 1.0, establish a public API baseline using:

* swift-api-digester; or
* Symbol-graph comparison with an equivalently strict gate.

Treat these as independent checks:

1. Public Swift source/API compatibility.
2. LocalAPI wire compatibility.
3. Supported daemon-version compatibility.

A stable public façade may intentionally adapt to wire changes without breaking consumers.

Acceptance criteria

* Every generated or hand-maintained wire contract records upstream provenance.
* Upstream Go fixtures cover all explicitly supported endpoints.
* Scheduled drift produces a reviewable, actionable report or PR.
* Compatibility evidence covers current stable, previous stable, and unstable daemons.
* The endpoint manifest records independent upstream maturity and Swift support.
* CI blocks accidental public Swift API breakage once the baseline is established.
* Release documentation states supported daemon versions and preview-endpoint risks.
* Capability-version updates are tied to the same upstream snapshot and compatibility review.
* No scheduled automation silently advances compatibility claims.
