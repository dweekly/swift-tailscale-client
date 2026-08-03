# Discovery & Permissions

How the client finds the LocalAPI, and the one macOS case that needs a
permission prompt.

## The discovery chain

`TailscaleClient()` (equivalently, `TailscaleClientConfiguration.default()`)
resolves the LocalAPI endpoint in this order:

1. **Environment variables** — `TAILSCALE_LOCALAPI_SOCKET`,
   `TAILSCALE_LOCALAPI_PORT`/`TAILSCALE_LOCALAPI_HOST` (+
   `TAILSCALE_LOCALAPI_AUTHKEY`), or `TAILSCALE_LOCALAPI_URL`. These always
   win, which makes CI and test setups trivial.
2. **Unix domain sockets** — Homebrew's `/var/run/tailscaled.socket`, the
   system daemon's `/Library/Tailscale/Data/tailscaled.sock`, and other known
   paths. This is the default path on macOS and Linux and triggers **no
   permission prompts**.
3. **macOS App Store GUI discovery** — only when explicitly enabled (below).

Set `TAILSCALE_DISCOVERY_DEBUG=1` to log every decision to stderr. Discovery
logging never emits authentication-token material — proof-file paths are
redacted because the filename embeds the token — and is regression-tested to
stay that way.

> Important: Some values this package hands **you** are secrets, and your
> logging is outside our control. Treat
> ``TailscaleClientConfiguration/authToken``, `idToken(audience:)` responses,
> ``CertPair/privateKeyPEM``, and any audit reason you supply as credentials:
> never log them or include them in bug reports.

## The App Store caveat (TCC)

The App Store build of Tailscale exposes its LocalAPI on a loopback port
whose port and token live in the app's Group Container. Reading another
app's Group Container triggers macOS's TCC prompt ("wants to access data
from other apps"), so this discovery path is **off by default** and must be
opted into:

```swift
let config = TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)
let client = TailscaleClient(configuration: config)
```

Only enable it when your users actually run the App Store build, and explain
the prompt to them before it appears. When enabled, discovery first uses
libproc (fast, ~5 ms) and falls back to scanning Group Containers;
`TAILSCALE_SAMEUSER_PATH`, `TAILSCALE_SAMEUSER_DIR`, and
`TAILSCALE_SKIP_LIBPROC` refine the behavior.

## Sandboxed apps

A sandboxed app needs the right entitlements to reach a unix socket or
another app's containers. Test discovery inside the sandbox early — it is
the most common integration surprise. The environment-variable overrides are
handy for isolating whether a failure is discovery or permissions.

## Auth tokens

Unix-socket connections need no token (the daemon authenticates the peer
process). Loopback TCP connections authenticate with a token sent as HTTP
basic auth; discovery fills it in automatically, or pass
`authToken:` / `TAILSCALE_LOCALAPI_AUTHKEY` explicitly.
