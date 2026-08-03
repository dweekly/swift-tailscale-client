Design a transport-neutral Swift LocalAPI core that can converge with TailscaleKit

Why

Tailscale already ships a functional but incomplete Swift LocalAPIClient inside TailscaleKit for embedded nodes.

Official Swift implementation:

https://github.com/tailscale/libtailscale/tree/main/swift

Existing client source:

https://github.com/tailscale/libtailscale/blob/main/swift/TailscaleKit/LocalAPI/LocalAPIClient.swift

This repository primarily addresses an installed local Tailscale instance.

The strongest upstream-adoption story is therefore one shared endpoint, model, and error layer with multiple transports—not two competing Swift LocalAPI clients.

Candidate architecture

* TailscaleLocalAPI
    * LocalAPIClient
    * public Swift façade types
    * internal wire models
    * endpoint definitions
    * error model
    * transport protocol
* InstalledDaemonTransport
    * Unix socket
    * authenticated loopback
    * explicit/custom endpoint
    * installed-client discovery
* EmbeddedNodeTransport
    * adapter for TailscaleKit's embedded node and loopback behavior
* Optional products
    * mocks and test fixtures
    * client-side diagnostics/netcheck
    * reference CLI

Design questions

* Can LocalAPIClient depend only on a transport protocol and shared models?
* Can the current Unix/loopback implementation become InstalledDaemonTransport?
* Can a small adapter support TailscaleKit without importing installed-daemon discovery?
* Should the public module/product become TailscaleLocalAPI?
* Can compatibility aliases preserve existing TailscaleClient consumers before 1.0?
* Should the core client remain a sendable value, become an actor, or use an internal actor only for shared streaming state?
* Which APIs belong in the adoption-sized core?
* Should the CLI remain in the package as a reference consumer or move to another package?
* Should netcheck and interface discovery move to an optional TailscaleDiagnostics product?
* Which platforms are runtime-supported by each transport?
* How should embedded and installed transports identify their capability/version provenance?

First deliverable: ADR

Write an architecture decision record before making breaking changes.

The ADR should compare:

* Current public API and TailscaleKit's API.
* Naming and module boundaries.
* Actor/concurrency models.
* Transport interfaces.
* Streaming and upgraded-connection requirements.
* Error types.
* Wire-model overlap.
* Platform and sandbox constraints.
* Dependency direction.
* Migration and deprecation strategy.
* Plausible locations for eventual upstream ownership.

Proof of concept

Run at least one representative endpoint through:

1. The installed-daemon Unix or loopback transport.
2. An embedded-node adapter or a structurally equivalent fake transport.

The proof should demonstrate that endpoint behavior and models contain no installed-daemon assumptions.

Acceptance criteria

* An ADR describes target modules, dependencies, naming, migration, and platform support.
* The proposed core has no dependency on discovery, CLI parsing, or client-side diagnostics.
* A proof of concept runs one endpoint through both installed and embedded/fake transports.
* Streaming, cancellation, and raw-upgrade requirements are represented in the transport design.
* Existing users have a source-compatible or clearly documented pre-1.0 migration path.
* Runtime support is documented per transport rather than inferred from SwiftPM build platforms.
* No large refactor begins until the upstream-design issue tests whether Tailscale wants this architecture.
