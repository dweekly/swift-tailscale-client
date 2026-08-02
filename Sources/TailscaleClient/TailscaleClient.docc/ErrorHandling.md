# Error Handling

What each error case means and how to respond to it.

## The error taxonomy

Every method throws ``TailscaleClientError``. The cases carry enough context
to act on — and `recoverySuggestion` turns most of them into a user-facing
sentence:

- ``TailscaleClientError/transport(_:)`` — couldn't reach the daemon at all:
  socket missing (`socketNotFound`), nothing listening
  (`connectionRefused`), or a lower-level network failure. Usually means
  Tailscale isn't running or discovery picked the wrong endpoint (see
  <doc:DiscoveryAndPermissions>).
- ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)`` — the daemon
  answered with a non-200. The body is preserved because the daemon's error
  strings ("no suggested exit node available") are often the real message.
- ``TailscaleClientError/decoding(_:body:endpoint:)`` — the response didn't
  match this package's models. The raw body is attached; please file an
  issue with it, since this usually signals an upstream schema change.
- ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` — the
  endpoint isn't in this daemon *build* (404 on an optional path, or 501
  when the feature was compiled out). `feature` names the build feature to
  check.
- ``TailscaleClientError/timeout(endpoint:)`` — the configured
  `requestTimeout` (default 30 s, `nil` disables) elapsed.

## The two meanings of 404

LocalAPI routing returns 404 both for *unknown paths* and for *known paths
with missing resources*, so this package splits them by endpoint class:

- On **optional endpoints** (`usermetrics`, `suggest-exit-node`,
  `dns-osconfig`, …) a 404/501 becomes `endpointUnavailable` — the daemon
  build simply lacks the surface.
- On **core lookups** (``TailscaleClient/peer(byID:)``,
  ``TailscaleClient/userProfile(byID:)``) a 404 stays
  `unexpectedStatus(404, …)` — it means "not in the netmap". (One wrinkle:
  `user-profile` is a 2026 addition, so on older daemons a 404 can also mean
  the path itself is unknown.)

## Probe, don't guess

Endpoint availability is build-dependent, not just version-dependent. When
your feature depends on an optional surface, probe once with
``TailscaleClient/daemonFeatures()`` and branch, rather than catching
failures on every call:

```swift
let features = try await client.daemonFeatures()
if features.isEnabled("use-exit-node") {
  let suggestion = try await client.suggestExitNode()
}
```

## A pattern that composes

```swift
do {
  let report = try await client.netcheck()
  render(report)
} catch let error as TailscaleClientError {
  switch error {
  case .transport:
    showBanner("Tailscale isn't running", detail: error.recoverySuggestion)
  case .endpointUnavailable:
    hideFeature()  // daemon build can't do this; don't nag the user
  default:
    log(error)     // includes endpoint + body context
  }
}
```
