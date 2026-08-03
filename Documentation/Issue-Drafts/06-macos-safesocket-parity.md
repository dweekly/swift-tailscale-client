Align macOS LocalAPI discovery and authentication with upstream safesocket

Why

Tailscale supports multiple macOS installation forms with different process and authentication arrangements.

Its Darwin safesocket implementation handles:

* Credentials supplied directly by a GUI/XPC context.
* sameuserproof discovery for separate CLI processes.
* Authenticated loopback connections.
* Port validation.
* Unix-socket fallback.

Darwin safesocket source:

https://github.com/tailscale/tailscale/blob/main/safesocket/safesocket_darwin.go

Platform distinctions:

https://tailscale.com/docs/reference/tailscaled

Current Swift discovery:

https://github.com/dweekly/swift-tailscale-client/blob/main/Sources/TailscaleClient/Configuration/LocalAPIDiscovery.swift

Our independent discovery order and Group Container scan are useful, but an official implementation needs an explicit, upstream-agreed security and compatibility contract.

Scope

Model installation flavor explicitly

Represent at least:

* macOS App Store GUI installation.
* Standalone notarized GUI/macsys installation.
* Open-source or Homebrew tailscaled.
* Explicit/custom endpoint.
* Embedded-node transport, where applicable.

Return or record non-secret provenance identifying which flavor and discovery mechanism won.

Define deterministic selection behavior

Compare our behavior step by step with upstream safesocket.

Decide whether automatic discovery should:

* Exactly mirror upstream ordering; or
* Return viable candidates and provenance, allowing callers to choose when multiple installations exist.

Do not silently connect to an arbitrary installation when multiple valid candidates are present unless that precedence is explicitly documented and tested.

Security validation

Review and test:

* File ownership.
* File type.
* Permission expectations.
* Symlink policy.
* Token parsing and length/format validation.
* Port range and liveness.
* Loopback-only enforcement.
* Time-of-check/time-of-use behavior.
* Stale proof files.
* Malicious or malformed proof files.
* Multiple users or containers.
* Cancellation and discovery deadlines.

TCC behavior

Keep permission-triggering Group Container discovery opt-in unless Tailscale provides a better supported mechanism.

Document:

* What permission prompt may appear.
* Why it appears.
* Which use cases require it.
* How callers can avoid it through explicit configuration.

Credential handling

No token material may be logged. The dedicated secret-redaction issue governs the repository-wide audit.

Testing

Build hermetic fixtures for:

* No installation available.
* Unix socket only.
* App Store loopback only.
* Standalone/macsys loopback only.
* Multiple simultaneous installations.
* Stale first candidate and live second candidate.
* Malformed or unauthorized proof files.
* Closed or reused loopback ports.
* Timeout and cancellation.
* TCC discovery disabled.

Acceptance criteria

* A supported installation and transport matrix is documented.
* Every discovery result contains non-secret provenance.
* Tests prove deterministic behavior with zero, one, or multiple discoverable installations.
* The implementation either has upstream safesocket parity or a documented, Tailscale-approved divergence.
* File and loopback security checks are explicit and tested.
* TCC behavior is opt-in, bounded, and documented.
* No credential material appears in logs or errors.
* The upstream proposal asks which third-party macOS credential mechanism Tailscale is willing to support.
