# Writing Safely

How to change daemon configuration without clobbering what the user set.

## The mask contract

`PATCH /localapi/v0/prefs` is not a merge of a partial object — the daemon
applies exactly the fields whose `<Name>Set` flag is true and ignores the
rest. ``MaskedPrefs`` encodes that contract structurally: setting a property
emits both the value and its flag; leaving it `nil` emits neither. Two
consequences worth internalizing:

- **Never round-trip full prefs through an edit.** Reading ``Prefs``,
  mutating one field, and writing everything back would overwrite
  concurrent changes (the GUI, another admin, an MDM profile). Send only
  the fields you mean to change:

```swift
var change = MaskedPrefs()
change.exitNodeID = selected.stableID
change.exitNodeAllowLANAccess = true
let updated = try await client.editPrefs(change)
```

- **The response is the new truth.** ``TailscaleClient/editPrefs(_:)``
  returns the daemon's full updated ``Prefs`` — update your UI from that,
  not from what you sent, because the daemon may normalize or reject parts
  of a change.

## Validate before you apply

For changes driven by user input (routes, tags, hostnames), ask the daemon
first: ``TailscaleClient/checkPrefs(_:)`` validates a complete ``Prefs``
without applying it, and the thrown
``TailscaleClientError/unexpectedStatus(code:body:endpoint:)`` carries the
daemon's human-readable objection — show it verbatim.

## Prefer the purpose-built endpoints

When a dedicated write endpoint exists, use it instead of a raw prefs edit —
it encodes semantics a mask can't:

- ``TailscaleClient/setUseExitNode(enabled:)`` toggles the exit node
  *without forgetting which node was selected*; a `MaskedPrefs` edit that
  clears `exitNodeID` loses the selection.
- ``TailscaleClient/setExpirySooner(_:)`` only moves key expiry earlier —
  the daemon enforces the direction.
- ``TailscaleClient/start(options:)`` is the sanctioned path for first-run
  and headless auth-key bring-up, not a prefs edit.

## Handle rejection as conversation, not failure

Write endpoints respond 400 with a plain-text reason ("exit node not
found", tag syntax errors). Treat these as user-facing validation messages;
`recoverySuggestion` covers the transport-level cases.

## Testing code that writes

Never point write tests at a tailnet anyone depends on. This package's own
mutation tests are double-gated (`TAILSCALE_INTEGRATION_WRITE=1`, set only
in a throwaway headscale environment) — mirror that pattern. For unit
tests, `TailscaleClientMocks` lets you assert the exact PATCH body your
code produces, which is the part worth pinning: mask correctness is the
whole game.
