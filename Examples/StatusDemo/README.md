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
.package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "1.1.0")
```

Hosted CI builds this example on macOS. The self-hosted macOS workflow runs it against a live daemon using an endpoint supplied by the workflow.
