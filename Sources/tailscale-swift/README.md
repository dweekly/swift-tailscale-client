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
