# Version Compatibility

How this package behaves across Tailscale daemon versions — and what to do
when the daemon is older or newer than you expect.

## The ground rules

The LocalAPI carries no version negotiation beyond a capability-version
header, and endpoint availability depends on **both** the daemon's release
version and its build configuration (modularized daemons compile features in
or out). This package's posture:

- **Tolerant decoding everywhere.** Newer daemons adding fields never breaks
  decoding; unknown JSON is ignored or captured losslessly (`JSONValue`,
  `CapabilityValue.raw`). A daemon upgrade should never turn a working app
  into a throwing one.
- **Probe, don't version-sniff.** ``TailscaleClient/daemonFeatures()``
  reports what the connected build actually supports; optional endpoints map
  404/501 to ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``
  so absence is a typed, recoverable condition.
- **Each release records what it was tested against** in the CHANGELOG; the
  hermetic CI matrix runs the suite against a real tailscaled nightly.

## Known version edges

Cases the package handles for you, worth knowing when supporting old
installs:

| Surface | Edge |
| --- | --- |
| `suggestExitNode(forceProbe:)` | `forceProbe: true` POSTs `?probe=true`, accepted since Tailscale 1.86; the default GET works on both older and newer daemons. |
| `userMetrics()` | Endpoint appeared in Tailscale 1.78; older daemons yield `endpointUnavailable`. |
| `userProfile(byID:)` | Endpoint added upstream in 2026. On older daemons the path itself 404s, which is indistinguishable from "user not found". |
| `watchIPNBus` extras | `initialPrefs`/`initialNetMap` notifications decode fully since v0.4.0 of this package. |
| CapMap values | Tailscale 1.98 started sending boolean arrays; any well-formed value decodes since v0.4.0. |

## Capability version

Requests send `Tailscale-Cap: 1` by default
(`TailscaleClientConfiguration.capabilityVersion`, override with
`TAILSCALE_LOCALAPI_CAPABILITY`). Raising it tells the daemon you understand
newer response shapes; leave it at the default unless you are deliberately
opting into a newer contract.

## When something still breaks

If a daemon change does slip past tolerant decoding, the thrown
``TailscaleClientError/decoding(_:body:endpoint:)`` carries the raw response
body — attach it to a GitHub issue and pin your dependency to the last good
minor version while it's fixed. Pre-1.0, minor versions of this package may
also adjust APIs; the CHANGELOG calls out every breaking change explicitly.
