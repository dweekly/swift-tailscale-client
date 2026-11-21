# Peer Diagnostics

A small Mac sample built on
[swift-tailscale-client](https://github.com/dweekly/swift-tailscale-client) (unofficial; not
affiliated with Tailscale Inc.). It lists the peers your existing Tailscale installation
knows about and, for the peer you pick, says how a ping reached it: directly, through a
peer relay, through DERP, or by a path the daemon did not name. Every result carries the
time it was measured and whether it is still current.

```bash
# From the repository root. Needs no Tailscale at all:
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics --fixture --print

# Against the Tailscale daemon already running on this Mac:
swift run --package-path Examples/PeerDiagnostics PeerDiagnostics --live --print
```

**Fixture mode** (the default) uses a built-in, made-up tailnet with documentation-range
addresses. Its peers are scripted to show each outcome: a direct reply, DERP upgrading to
direct, a peer relay, DERP only, a reply with no path, an offline peer that times out, and a
daemon error. It needs no daemon, no permission, and no network.

**Live mode** finds the local daemon with the library's default discovery and reads only:
`status`, a watch on the daemon's event bus (to learn when peers change), and disco pings to
the peer you select. It never writes to the daemon. Discovery of the Mac App Store edition is
off unless you pass `--allow-app-store-discovery`, because it can make macOS ask for
permission to read another app's data.

A ping burst sends up to 5 pings one second apart and stops at the first direct reply, the
first failure, or the fifth ping; each ping waits at most 5 seconds. A burst that ends on a
DERP or relayed reply is reported as one measurement of that ping, not as the peer's settled
path.

All state and logic live in the `PeerDiagnosticsCore` library and are tested without a
daemon: `swift test --package-path Examples/PeerDiagnostics`. The package depends on the
library through `.package(path: "../..")`; to use it as a template, replace that with the
released package URL.
