Roadmap: make swift-tailscale-client upstream-adoptable by Tailscale

Goal

Make this project a credible candidate for adoption, incorporation, or shared ownership by Tailscale as its official Swift LocalAPI implementation.

This does not assume Tailscale wants to support third-party access to an installed client's LocalAPI. That remains a product and support-policy decision only Tailscale can make. Our objective is to remove avoidable technical, architectural, security, documentation, and governance obstacles so that the answer can be based on product strategy rather than implementation risk.

Guiding principle

Optimize for code Tailscale can absorb—not merely for maximum endpoint count in an independent wrapper.

Tailscale already maintains:

* The canonical Go LocalAPI client:
    https://pkg.go.dev/tailscale.com/client/local
* An incomplete Swift LocalAPI implementation inside TailscaleKit:
    https://github.com/tailscale/libtailscale/tree/main/swift

The strongest adoption path is therefore likely a transport-neutral Swift LocalAPI core usable by both TailscaleKit's embedded node and this package's installed-daemon transports.

Phase 0: resolve immediate contract and security concerns

* Never log LocalAPI authentication-token material
* Track upstream maturity separately from Swift API stability
* Match the upstream request, capability, version, and error contract

These should precede further broad endpoint expansion.

Phase 1: establish upstream parity and architectural convergence

* Close gaps in Tailscale's explicitly stable LocalAPI surface
* Design a transport-neutral core that can converge with TailscaleKit
* Align macOS discovery and authentication with upstream safesocket
* Pin wire contracts and automate upstream/API drift detection

Phase 2: prepare the adoption conversation

* Prepare the upstream proposal, contribution posture, and governance

Cross-cutting decisions

Separate two kinds of stability

Every endpoint needs two independent classifications:

1. Tailscale's stated maturity for the daemon endpoint.
2. This package's support and SemVer commitment for its Swift façade.

A stable Swift façade may normalize changes in an unstable daemon endpoint, but the documentation must say that explicitly rather than implying an upstream guarantee.

Prefer stable parity over unstable breadth

Before implementing additional debug, Tailnet Lock, Taildrop, Taildrive, or GUI-contract endpoints, complete or explicitly disposition the LocalAPI methods Tailscale documents as stable.

Avoid a static "latest capability" constant

The default capability version should be generated or deliberately pinned to a tested upstream revision and its modeled semantics. It should not remain at 1 indefinitely, but it also should not be bumped to the latest upstream integer without compatibility evidence.

Keep the adoption-sized core narrow

The core should contain endpoint behavior, transport abstractions, errors, and models. The CLI, installed-daemon discovery, client-side netcheck, and interface diagnostics should not be mandatory dependencies of that core.

Definition of success

The project is ready for a serious upstream conversation when:

* Upstream maturity and Swift support promises are independently accurate.
* No credentials or secret-bearing values can leak through diagnostics.
* Capability negotiation, version mismatch handling, audit reasons, errors, and rate limiting follow the canonical client's behavior.
* The explicitly stable LocalAPI surface has an auditable parity ledger.
* Wire types and endpoint metadata have upstream provenance and automated drift detection.
* macOS installation discovery has an agreed security and compatibility contract.
* A transport-neutral design can serve installed-daemon and embedded-node use cases.
* Public API breakage is mechanically gated before 1.0.
* DCO, licensing, security response, maintenance succession, and contribution policy are credible.
* The proposal asks Tailscale for the policy decisions only Tailscale can make.

Non-goals

* Claiming affiliation or official status before Tailscale grants it.
* Treating all LocalAPI endpoints as stable.
* Reimplementing the complete Tailscale CLI in Swift.
* Forcing TailscaleKit consumers to depend on installed-daemon discovery.
* Automatically updating generated contracts without review.
* Opening an upstream issue or Community Projects submission without maintainer approval.
