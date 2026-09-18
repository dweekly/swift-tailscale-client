# Discovery & Permissions

How the client finds the LocalAPI, and the one macOS case that needs a permission prompt.

## Overview

Tailscale runs in diverse environments across macOS and Linux: as a system daemon (`tailscaled`), as a standalone installer package (`.pkg`), as a sandboxed App Store application, or inside containers. `TailscaleClient` automatically discovers the active LocalAPI endpoint and handles credential recovery transparently.

### The Discovery Chain

When initialized without explicit parameters, `TailscaleClient()` uses ``LocalAPIDiscovery`` to resolve the active endpoint in this order:

1. **Environment overrides**: `TAILSCALE_LOCALAPI_SOCKET`, `TAILSCALE_LOCALAPI_PORT`/`TAILSCALE_LOCALAPI_HOST` (with `TAILSCALE_LOCALAPI_AUTHKEY`), or `TAILSCALE_LOCALAPI_URL`. These always take precedence, which makes CI and test fixtures straightforward.
2. **Unix domain sockets**:
   - macOS standalone and Homebrew: `/var/run/tailscaled.socket`
   - System daemon: `/Library/Tailscale/Data/tailscaled.sock`
   - Linux systemd socket: `/run/tailscale/tailscaled.sock`
3. **macOS standalone `.pkg` application**: Resolves `/Library/Tailscale/ipnport` symlink and its corresponding token file.
4. **macOS App Store GUI discovery**: Loopback port and authentication proof file located in Tailscale's Group Container (requires opt-in due to TCC permissions).

Set `TAILSCALE_DISCOVERY_DEBUG=1` to log each discovery step to stderr. Discovery logging redacts token values and filenames containing proof tokens.

### Standalone macOS .pkg App Discovery

The standalone `.pkg` distribution of Tailscale (installed to `/Applications/Tailscale.app`) runs the daemon in a system location and publishes its loopback TCP port via a symlink at `/Library/Tailscale/ipnport`. The corresponding authentication token is located in `/Library/Tailscale/ipnport.token`.

Because this directory is world-readable, `swift-tailscale-client` discovers and connects to the standalone `.pkg` distribution without triggering any macOS TCC dialogs.

### Asynchronous Discovery with discoverAsync()

In addition to synchronous `discover()`, `LocalAPIDiscovery` provides ``LocalAPIDiscovery/discoverAsync()``:

```swift
let discovery = LocalAPIDiscovery()
let result = try await discovery.discoverAsync()
print("Discovered LocalAPI at: \(result.endpoint)")
```

`discoverAsync()` cooperatively checks task cancellation and probes socket readiness asynchronously, preventing thread starvation during app launch.

### EndpointSource and Dynamic Credential Refresh

When creating a `TailscaleClient`, its configuration tracks an ``EndpointSource``:

- ``EndpointSource/automatic(_:)`` (default): The client knows how the endpoint was discovered. If the daemon restarts while the client is running (causing `ECONNREFUSED` or HTTP 401/403 due to an ephemeral port or token change), the client automatically re-probes discovery and updates its active endpoint and credentials seamlessly.
- ``EndpointSource/pinned(_:)``: Targets a static endpoint explicitly configured by the developer and never attempts dynamic rediscovery.

### The macOS App Store Caveat (TCC)

The App Store build of Tailscale exposes its LocalAPI on a dynamic loopback port whose proof file lives in the app's Group Container (`~/Library/Group Containers/group.com.tailscale.ipn.macsys`). Reading another application's Group Container triggers macOS's TCC prompt ("wants to access data from other apps"), so App Store discovery is **disabled by default**:

```swift
let config = TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)
let client = TailscaleClient(configuration: config)
```

Only enable `allowMacOSAppStoreDiscovery` when your users run the App Store build, and consider informing them why the system prompt will appear.

### Sandboxed Applications

Sandboxed applications need appropriate entitlements (such as network client entitlements or App Sandbox exceptions) to connect to Unix domain sockets or external loopback ports. If discovery fails with ``LocalAPIDiscoveryError/inaccessible(path:reason:)``, verify sandbox entitlements.

### Authentication Tokens

Unix socket connections do not require an HTTP authentication token because the operating system kernel authenticates the peer process. TCP loopback connections require an HTTP token sent as basic authentication; discovery extracts this token automatically and injects it into all LocalAPI requests.

## Topics

### Discovery Machinery
- ``LocalAPIDiscovery``
- ``LocalAPIDiscoveryError``
- ``TailscaleEndpoint``
- ``EndpointSource``

### Configuration
- ``TailscaleClientConfiguration``

