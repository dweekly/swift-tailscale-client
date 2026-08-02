# StatusDemo

A minimal, copy-paste-ready consumer of
[swift-tailscale-client](https://github.com/dweekly/swift-tailscale-client):
it connects to the local tailscaled, prints node identity and peer count,
probes the daemon's optional features, and runs a client-side STUN netcheck.

```bash
swift run   # from this directory; requires a running Tailscale
```

This package depends on the library via `.package(path: "../..")` so CI can
build and run it against the exact code under review. To use it as a template
for your own project, replace the path dependency with:

```swift
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.6.0")
```

CI builds this example on macOS and Linux on every PR, and the self-hosted
integration workflow *runs* it against a real daemon — so the example is
continuously verified end-to-end, not just compiled.
