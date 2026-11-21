# tailscale-swift

Development CLI tool for testing and exploring the swift-tailscale-client library.

> **Note:** This is a development-only tool and is not included in the published package. It's used by maintainers for testing and debugging the TailscaleClient library.

## Building

```bash
swift build
```

The binary will be built to `.build/debug/tailscale-swift`.

## Usage

### Check Status

Display current Tailscale daemon status:

```bash
.build/debug/tailscale-swift status
```

**Output:**
```
=== Tailscale Status ===
Backend State: running
Version: 1.88.3

=== Self Node ===
Hostname: my-machine
ID: abc123
User ID: 12345
Online: true
Exit Node: false
Tailscale IPs: 100.64.0.1, fd7a:...

=== Network ===
Magic DNS Suffix: example.ts.net
Current Tailnet: example.com

=== Peers (7) ===
Online: 5/7
```

### Verbose Mode

Show detailed information about all peers:

```bash
.build/debug/tailscale-swift status --verbose
```

**Output:**
```
...
=== Peers (7) ===

Peer: peer-hostname-1
  ID: xyz789
  Online: true
  IPs: 100.64.0.2, fd7a:...
  Last Seen: 2025-09-30 14:30:00 +0000

Peer: peer-hostname-2
  ID: abc456
  Online: false
  IPs: 100.64.0.3
```

### Ping a Peer

```bash
.build/debug/tailscale-swift ping 100.64.0.2 --count 3
```

**Output** (a live, sanitized run; each reply names the path it took, like `tailscale ping`):
```
PING 100.64.0.2 using disco...
ping 1: example-peer - 5.99 ms via [2001:db8::a]:41641
ping 2: example-peer - 3.63 ms via [2001:db8::a]:41641
ping 3: example-peer - 3.07 ms via [2001:db8::a]:41641

--- 100.64.0.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
avg latency: 4.23 ms
```

Paths print as `via <ip:port>` (direct), `via peer-relay(<endpoint>)`,
`via DERP(<code>)` (or `DERP(region <id>)` without a code), or the ping type
(`via TSMP`, `via ICMP`, `via peerapi`) when the reply names no path. Failed
pings print `error - <message>`. `--type` takes `disco`, `tsmp`, `icmp`, or
`peerapi` (`peerAPI` also works); `--json` prints the raw replies as an array.
### Watch the IPN Bus

Stream state changes until Ctrl+C:

```bash
.build/debug/tailscale-swift watch               # initial state, health, rate limiting
.build/debug/tailscale-swift watch --all-initial # all initial state, engine stats
.build/debug/tailscale-swift watch --reconnect   # reconnect when the daemon restarts
```

Tailscale 1.104 and later reject rate limiting and the initial network map; the
watch is opened again without them. When a daemon rejects a watch, the command
prints the daemon's message (`Daemon said: ...`) and exits non-zero.

## Help

```bash
.build/debug/tailscale-swift --help
.build/debug/tailscale-swift status --help
```

## Adding New Subcommands

To add a new subcommand:

1. Create a new file in `Sources/tailscale-swift/` (e.g., `Ping.swift`)
2. Implement `AsyncParsableCommand`:
   ```swift
   import ArgumentParser
   import TailscaleClient

   struct Ping: AsyncParsableCommand {
     static let configuration = CommandConfiguration(
       abstract: "Ping a peer"
     )

     @Argument(help: "Hostname or IP to ping")
     var target: String

     func run() async throws {
       // Implementation
     }
   }
   ```
3. Add to `TailscaleSwift.swift` subcommands array:
   ```swift
   subcommands: [Status.self, Ping.self]
   ```

## Requirements

- Tailscale daemon running locally
- macOS 13+ (uses LocalAPI discovery)
- Swift 6.1+
