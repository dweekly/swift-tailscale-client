Close gaps in Tailscale's explicitly stable LocalAPI surface

Goal

Before expanding further into unstable or debug endpoints, establish parity with the LocalAPI methods Tailscale explicitly documents as stable.

Authoritative method list:

https://pkg.go.dev/tailscale.com/client/local

Deliverable: a generated stable-parity ledger

For a pinned upstream Tailscale revision, list every explicitly stable method and classify it as:

* Implemented and supported.
* Implemented under a different Swift symbol.
* Intentionally deferred, with rationale.
* Not applicable to supported transports or platforms.
* Missing.

Do not count unannotated methods as stable. Tailscale's package documentation says they must be assumed unstable.

Known implementation or classification gaps

WhoIs variants

Add the stable variants for:

* Protocol-specific lookup.
* Node-key lookup.
* Destination-IP-scoped lookup.
* Service-scoped lookup.

Use typed inputs where practical, preserve tolerant response decoding, and produce a typed peer-not-found error.

CheckUpdate

Implement CheckUpdate over update/check as a supported read.

This should not imply that the package itself installs updates. It reports the daemon's update information and availability semantics.

DisconnectControl

Implement and accurately document DisconnectControl.

Upstream describes it as useful for gracefully removing HA subnet-router or app-connector replicas before shutdown. It is not merely a daemon test-harness function.

Because it has operational impact:

* Use explicit administrative naming.
* Document consequences.
* Never exercise it against a real user daemon in default tests.
* Require deliberate CLI confirmation if exposed through the reference CLI.

BugReport

Promote BugReport from the experimental namespace or provide a supported façade while retaining a migration path.

Keep genuinely unstable debug operations separate.

Stable overloads and details

Verify parity for:

* StatusWithoutPeers
* SwitchToEmptyProfile
* SwitchProfile
* CurrentDERPMap
* CertDomains
* CertPair and minimum-validity behavior
* Certificate rate-limit retry handling
* StartLoginInteractive
* SetUseExitNode
* Other explicitly stable methods present in the pinned upstream revision

DialTCP and UserDial

DialTCP and UserDial are explicitly stable upstream but require HTTP connection upgrade and a raw duplex stream.

Conduct a design spike for a Swift abstraction such as a sendable, cancellable TailscaleConnection that supports:

* Independent asynchronous reads and writes.
* Half-close or documented close semantics.
* Cancellation.
* Backpressure.
* Unix-socket and loopback transports.
* Correct ownership of the upgraded connection.

Ordinary URLSession request/response behavior is not sufficient. Split the implementation into a dedicated child issue if needed after agreeing on the abstraction.

Testing

* Fixture tests for all new response and error types.
* Request-recorder tests for exact method, path, query, headers, and status handling.
* Hermetic daemon tests for mutating or disruptive methods.
* Live read-only tests where safe.
* Cancellation and lifecycle tests for upgraded connections.
* Compatibility tests across supported daemon lanes.

Acceptance criteria

* The stable-parity ledger is generated or mechanically validated.
* All small and ordinary stable gaps are implemented and documented.
* Every deferred stable method has a concrete rationale and follow-up disposition.
* DialTCP/UserDial has an approved Swift connection design and either an implementation or narrowly scoped child issue.
* Administrative methods have explicit naming, consequences, and safe test boundaries.
* Documentation no longer describes upstream-stable operations as internal test-only endpoints.
* Unstable endpoint breadth is tracked separately from stable parity.
