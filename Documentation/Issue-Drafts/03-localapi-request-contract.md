Match the upstream LocalAPI request, capability, version, and error contract

Why

The package currently advertises Tailscale-Cap: 1 by default.

Tailscale's canonical Go LocalAPI client sends tailcfg.CurrentCapabilityVersion. As of 2026-08-02 that value is 144 and changes as Tailscale evolves.

Current Swift configuration:

https://github.com/dweekly/swift-tailscale-client/blob/main/Sources/TailscaleClient/Configuration/TailscaleClientConfiguration.swift

Upstream request behavior:

https://github.com/tailscale/tailscale/blob/main/client/local/local.go

Capability history:

https://github.com/tailscale/tailscale/blob/main/tailcfg/tailcfg.go

Public Go API:

https://pkg.go.dev/tailscale.com/client/local

Hard-coding the latest number would be unsafe, but remaining at capability 1 indefinitely also misrepresents which semantics the Swift client understands.

The upstream client additionally:

* Examines the Tailscale-Version response header.
* Surfaces client/daemon version mismatches.
* Supplies an optional audit reason for supported writes.
* Produces typed errors for important status classes.
* Exposes certificate rate-limit retry timing.

Scope

Capability provenance

* Define a tested supportedCapabilityVersion.
* Tie it to a pinned upstream revision and the wire semantics represented by our models.
* Preserve explicit configuration and environment overrides.
* Document why and when the default may be advanced.
* Do not automatically claim every new upstream capability merely because tolerant decoding ignores unknown fields.

Version mismatch behavior

* Inspect the Tailscale-Version response header.
* Expose a nonfatal mismatch diagnostic, callback, or structured response metadata.
* Avoid failing requests that remain wire-compatible.
* Include client package version, advertised capability, and daemon version in diagnostics without exposing secrets.

Typed errors

Add or align typed handling for:

* HTTP 403 access denied
* HTTP 404 peer not found where applicable
* HTTP 404/501 optional feature unavailable
* HTTP 412 precondition failed
* HTTP 429 rate limited, including Retry-After
* malformed or incompatible daemon responses
* version/capability mismatch diagnostics

Audit reasons

Expose an optional request reason for mutating operations using the header and Base64 encoding expected by the upstream client. The public API should make this easy to supply consistently without adding a bespoke parameter to every method.

Acceptance criteria

* The default capability has documented upstream provenance.
* Compatibility tests prove the supported capability against the daemon matrix.
* A documented update procedure explains when and how the capability may be bumped.
* Explicit environment/configuration overrides continue to work.
* Tailscale-Version mismatches are observable without failing otherwise valid requests.
* Typed-error tests cover representative 403, 404, 412, 429, and feature-unavailable responses.
* Certificate rate-limit responses expose retry timing.
* Write APIs can supply an auditable request reason.
* Documentation distinguishes daemon version, capability version, endpoint availability, and compile-time feature gates.
* Stable, previous-stable, and unstable daemon lanes continue to pass.
