Track upstream LocalAPI maturity separately from Swift API stability

Why

Tailscale documents LocalAPI stability method by method. Its canonical Go package states that methods without an explicit API-maturity declaration must be assumed unstable.

Authoritative documentation:

https://pkg.go.dev/tailscale.com/client/local

Our Documentation/endpoints.json currently has one stability field. That conflates two different promises:

1. Whether Tailscale considers the daemon endpoint stable.
2. Whether this package promises a stable Swift façade.

Current manifest:

https://github.com/dweekly/swift-tailscale-client/blob/main/Documentation/endpoints.json

Known mismatches

Representative examples include:

* watch-ipn-bus: explicitly unstable upstream; Stable in our matrix.
* dns-osconfig: explicitly unstable upstream; Stable in our matrix.
* check-ip-forwarding: explicitly unstable upstream; Stable in our matrix.
* serve-config: GetServeConfig is explicitly unstable upstream; Stable in our matrix.
* ping, logout, profile-management operations, and several other methods have no upstream maturity annotation and therefore must be treated as upstream-unstable.
* bugreport: explicitly stable upstream; Experimental in our package.
* update/check: explicitly stable upstream; Experimental and unimplemented in our package.
* DialTCP and UserDial: explicitly stable upstream; unsupported in our package.
* disconnect-control: explicitly stable with a production HA shutdown use case; documented by us as a test-harness tool.

Proposed manifest model

Extend the existing manifest rather than creating a second source of truth.

Candidate fields:

* upstream_maturity: stable, unstable, or unspecified
* swift_support: supported, preview, or experimental
* upstream_symbol: corresponding Go method when one exists
* upstream_revision: revision against which the classification was verified
* upstream_notes: narrowly scoped compatibility caveats

unspecified must render as upstream-unstable unless Tailscale subsequently documents a stronger guarantee.

The existing upstream field describing general, debug, or gui-contract concerns a different dimension and should not substitute for maturity.

Documentation behavior

Generated documentation should make claims such as:

* "Upstream stable; supported Swift API"
* "Upstream unstable; supported Swift normalization layer"
* "Upstream unstable; preview Swift API"
* "No upstream maturity declaration; treat as unstable"
* "Upstream stable; not yet implemented"

This vocabulary is more accurate than applying one undifferentiated Stable label.

Acceptance criteria

* Every implemented endpoint has independent upstream-maturity and Swift-support values.
* The documentation generator renders both dimensions in LOCALAPI-COVERAGE.md and INTEGRATING.md.
* The known mismatches above are corrected.
* CI rejects missing classifications and invalid combinations.
* Public documentation explains precisely what the package promises when wrapping an unstable endpoint.
* Each classification records an upstream revision or version and verification date.
* A generated report identifies upstream-stable methods that are missing from the Swift client.
* Existing consumers receive migration guidance for any namespace or symbol changes caused by reclassification.
