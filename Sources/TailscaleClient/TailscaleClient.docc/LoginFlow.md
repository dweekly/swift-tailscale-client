# The Login Flow

Drive interactive authentication from your app using the IPN bus.

## How Tailscale login works

Interactive login is a three-party dance: your app asks the daemon to start,
the control plane issues a URL the *user* must open in a browser, and the
daemon reports completion as a state change. The URL arrives asynchronously —
on the IPN bus, not in the HTTP response — so the correct order is
**subscribe first, then start**:

```swift
let client = TailscaleClient()

let notifications = try await client.watchIPNBus(options: [.initialState])
try await client.loginInteractive()

for try await notify in notifications {
  if let url = notify.browseToURL {
    openInBrowser(url)  // NSWorkspace.shared.open / UIApplication.open
  }
  if notify.state == .running {
    break  // authenticated and up
  }
  if notify.state == .needsLogin, let error = notify.errMessage {
    throw LoginFailed(error)
  }
}
```

``TailscaleClient/loginInteractive()`` itself returns immediately (204); all
signal comes from the stream.

## Headless bring-up

Machines without a browser authenticate with an auth key instead —
``TailscaleClient/start(options:)`` with ``StartOptions/authKey`` — no bus
choreography required.

## Profiles: one daemon, many identities

The `profiles/` family manages saved account/tailnet pairings:
``TailscaleClient/profiles()`` and ``TailscaleClient/currentProfile()`` are
read-only; ``TailscaleClient/addProfile()`` creates-and-switches to an empty
profile (follow with a login), ``TailscaleClient/switchProfile(_:)`` changes
the active identity, and ``TailscaleClient/deleteProfile(_:)`` removes one.
Switching restarts the backend — expect a state dip on the IPN bus.

## The destructive pair

``TailscaleClient/logout()`` expires the node's keys (re-auth required);
``TailscaleClient/resetAuth()`` clears local auth state without contacting
control. Neither is ever exercised by this package's integration suites —
wire shapes are pinned by unit tests instead. Treat them the same way in
your app: confirm with the user, and never call them in test code aimed at
a real tailnet.
