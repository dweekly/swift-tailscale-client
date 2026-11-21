# Version Compatibility

How this package behaves across Tailscale daemon versions — and what to do
when the daemon is older or newer than you expect.

## Overview

### The ground rules

The LocalAPI carries no version negotiation beyond a capability-version
header, and endpoint availability depends on **both** the daemon's release
version and its build configuration (modularized daemons compile features in
or out). This package's posture:

- **Tolerant decoding everywhere.** Newer daemons adding fields never breaks
  decoding; unknown JSON is ignored or captured losslessly (`JSONValue`,
  `CapabilityValue.raw`, `ServeConfig` unmodeled fields). A daemon upgrade should never turn a working app
  into a throwing one.
- **Probe, don't version-sniff.** ``TailscaleClient/daemonFeatures()``
  reports what the connected build actually supports; optional endpoints map
  404/501 to ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``
  so absence is a typed, recoverable condition.
- **Each release records what it was tested against** in the CHANGELOG; the
  hermetic CI matrix runs the suite against a real tailscaled nightly.

### Known version edges

Cases the package handles for you, worth knowing when supporting old
installs:

| Surface | Edge |
| --- | --- |
| `suggestExitNode(forceProbe:)` | `forceProbe: true` POSTs `?probe=true`, accepted since Tailscale 1.86; the default GET works on both older and newer daemons. |
| `userMetrics()` | Endpoint appeared in Tailscale 1.78; older daemons yield `endpointUnavailable`. |
| `userProfile(byID:)` | Endpoint added upstream in 2026. On older daemons the path itself 404s, which is indistinguishable from "user not found". |
| `watchIPNBus` options | Tailscale 1.104 and later answer a watch that sets ``NotifyWatchOpt/initialNetMap`` or ``NotifyWatchOpt/rateLimit`` (including ``NotifyWatchOpt/default`` and ``NotifyWatchOpt/allInitial``) with HTTP 400 and no longer send ``IPNNotify/netMap``. The client opens the watch again without those two options and leaves them out of later watches from the same client; a daemon that accepts them receives exactly the options you pass. Follow peers with ``NotifyWatchOpt/peerChanges`` and re-read `status()` (see <doc:RecipeMonitoring>). |
| `watchIPNBus` notifications | `initialPrefs` notifications decode fully since v0.4.0 of this package. On pre-1.104 daemons `initialNetMap` arrives as raw JSON in ``IPNNotify/netMap``. Fields from ``NotifyWatchOpt/initialStatus`` and the peer-change options are not modeled yet; such notifications still decode. |
| CapMap values | Tailscale 1.98 started sending boolean arrays; any well-formed value decodes since v0.4.0. |

### Capability version

Requests send `Tailscale-Cap: 152` by default
(``TailscaleClientConfiguration/defaultCapabilityVersion``, override with
``TailscaleClientConfiguration/capabilityVersion`` or the
`TAILSCALE_LOCALAPI_CAPABILITY` environment variable). The default is pinned
to the upstream revision this package was tested against — see the
constant's documentation for provenance and the update procedure. Changing
it tells the daemon you understand a different contract; leave it at the
default unless you are deliberately opting into one.

### When something still breaks

If a daemon change does slip past tolerant decoding, the thrown
``TailscaleClientError/decoding(_:body:endpoint:)`` carries the raw response
body — attach it to a GitHub issue and pin your dependency to the last good
version while it's fixed. From 1.0 onward, breaking changes follow SemVer major releases.

## Topics

### Diagnostics & Compatibility
- ``OptionalFeatures``
- ``VersionDiagnostics``
- ``TailscaleClientConfiguration``
- ``TailscaleClientError``

