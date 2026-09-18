# Writing Safely

How to change daemon configuration without clobbering what the user set.

## Overview

Modifying live Tailscale daemon state carries the risk of clobbering concurrent user actions, administrative policy changes, or daemon-managed updates. `TailscaleClient` implements two distinct concurrency patterns to prevent state destruction: **field-level delta masks** for node preferences, and **document-level optimistic concurrency** for Serve and Funnel configurations.

### Two Concurrency Patterns: Delta Masks vs Document Snapshots

| Configuration Domain | Mechanism | Upstream Operation | Conflict Handling |
| :--- | :--- | :--- | :--- |
| **Node Preferences** (exit nodes, routing, shields) | ``MaskedPrefs`` field-level delta | `PATCH /localapi/v0/prefs` | Non-conflicting fields merge cleanly |
| **Serve & Funnel** (handlers, port routing, web servers) | ``ServeConfigSnapshot`` ETag snapshot | `POST /localapi/v0/serve-config` | Stale writes fail with HTTP 412 (``TailscaleClientError/preconditionFailed(body:endpoint:)``) |

### The Mask Contract for Preferences

`PATCH /localapi/v0/prefs` is not a replacement of the entire preference object. The daemon applies only those fields whose corresponding `<Name>Set` mask flag is `true` and leaves all other preferences unchanged. ``MaskedPrefs`` models this structurally: setting a property automatically marks its set flag, while leaving a property `nil` omits it from the patch entirely:

```swift
var change = MaskedPrefs()
change.exitNodeID = selected.stableID
change.exitNodeAllowLANAccess = true
let updated = try await client.editPrefs(change)
```

**Never round-trip full preferences through an edit.** Reading full ``Prefs``, mutating one field, and writing everything back will overwrite concurrent changes made by the GUI or MDM policies.

The response from ``TailscaleClient/editPrefs(_:)`` returns the daemon's full updated ``Prefs``. Always update application state from the response rather than assuming your proposed patch was accepted without normalization.

### Document-Level Optimistic Concurrency for Serve and Funnel

Unlike node preferences, Tailscale Serve and Funnel configs represent a complete routing tree (`ServeConfig`). Updating a single port handler requires replacing the configuration document.

To prevent silent overwrites when multiple tools or agents manage Serve handlers, `TailscaleClient` requires an optimistic concurrency snapshot:

```swift
// 1. Fetch current configuration and its active ETag
let snapshot = try await client.serveConfigSnapshot()

// 2. Modify a copy of the configuration
var updatedConfig = snapshot.config
updatedConfig.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:3000")

// 3. Commit the change only if the ETag hasn't changed
let newSnapshot = try await client.setServeConfig(updatedConfig, matching: snapshot)
```

If another client modified Serve in the interim, `setServeConfig` fails immediately with ``TailscaleClientError/preconditionFailed(body:endpoint:)``. When an unconditional replacement is explicitly required, use ``TailscaleClient/replaceServeConfigUnconditionally(_:)``.

### Validate Before You Apply

For changes driven by user input (such as subnet routes, tags, or hostnames), validate first: ``TailscaleClient/checkPrefs(_:)`` tests a complete ``Prefs`` object against daemon policies without applying it. If validation fails, the thrown ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)`` carries the daemon's descriptive objection.

### Prefer Purpose-Built Endpoints

When a specialized write endpoint exists, prefer it over a generic preferences edit:
- ``TailscaleClient/setUseExitNode(enabled:)`` toggles the exit node without forgetting which exit node was previously selected.
- ``TailscaleClient/setExpirySooner(_:)`` moves key expiry earlier without permitting accidental extension.
- ``TailscaleClient/start(options:)`` is the designated endpoint for first-run initialization and auth-key onboarding.

### Handle Rejections Gracefully

Write endpoints return HTTP 400 with a plain-text explanation when a configuration is rejected (e.g., "exit node not found" or syntax errors). Treat these messages as user-facing validation errors and display them directly.

### Testing Code That Writes

Never run mutation tests against a production tailnet. In this repository, mutation suites are gated behind `TAILSCALE_INTEGRATION_WRITE=1` and run only against ephemeral Headscale test containers. In unit tests, use `TailscaleClientMocks` to assert the exact HTTP method, path, and request body produced by your code.

## Topics

### Concurrency & Preference Models
- ``MaskedPrefs``
- ``Prefs``
- ``ServeConfigSnapshot``
- ``ServeConfig``

### Error Models
- ``TailscaleClientError``

