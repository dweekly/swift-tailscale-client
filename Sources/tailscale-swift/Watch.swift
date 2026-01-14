// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import ArgumentParser
import Foundation
import TailscaleClient

struct WatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch",
    abstract: "Watch the IPN bus for real-time state changes"
  )

  @Flag(name: .shortAndLong, help: "Output raw JSON instead of formatted text")
  var json = false

  @Flag(name: .shortAndLong, help: "Include engine stats (traffic counters)")
  var engine = false

  @Flag(name: .long, help: "Include all initial state in first message")
  var allInitial = false

  @MainActor
  func run() async throws {
    let client = TailscaleClient()

    var options: NotifyWatchOpt = [.initialState, .initialHealthState, .rateLimit]
    if engine {
      options.insert(.engineUpdates)
    }
    if allInitial {
      options = .allInitial
      options.insert(.engineUpdates)
      options.insert(.rateLimit)
    }

    print("Watching IPN bus (Ctrl+C to stop)...")
    fflush(stdout)

    var isFirstMessage = true

    do {
      let stream = try await client.watchIPNBus(options: options)

      for try await notify in stream {
        if json {
          printJSON(notify)
        } else {
          printFormatted(notify, isFirst: isFirstMessage)
        }
        isFirstMessage = false
        fflush(stdout)
      }
      print("Stream ended")
    } catch {
      print("Error: \(error)")
      throw error
    }
  }

  private func printJSON(_ notify: IPNNotify) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(notify),
      let string = String(data: data, encoding: .utf8)
    {
      print(string)
    }
  }

  private func printFormatted(_ notify: IPNNotify, isFirst: Bool) {
    let timestamp = ISO8601DateFormatter().string(from: Date())

    // Version/SessionID (first message only)
    if isFirst, let version = notify.version {
      print("[\(timestamp)] Connected to tailscaled \(version)")
      if let sessionID = notify.sessionID {
        print("  Session: \(sessionID)")
      }
    }

    // State changes
    if let state = notify.state {
      let emoji = stateEmoji(state)
      print("[\(timestamp)] \(emoji) State: \(state)")
    }

    // Error messages
    if let err = notify.errMessage {
      print("[\(timestamp)] ❌ Error: \(err)")
    }

    // Login finished
    if notify.loginFinished == true {
      print("[\(timestamp)] ✓ Login completed")
    }

    // Browse to URL (OAuth)
    if let url = notify.browseToURL {
      print("[\(timestamp)] 🔗 Open in browser: \(url)")
    }

    // Health state
    if let health = notify.health {
      if health.hasWarnings, let warnings = health.warnings {
        print("[\(timestamp)] ⚠️  Health warnings:")
        for (code, warning) in warnings {
          let title = warning.title ?? code
          let text = warning.text ?? ""
          print("  - \(title): \(text)")
        }
      } else {
        print("[\(timestamp)] ✓ Health: OK")
      }
    }

    // Engine stats
    if let engine = notify.engine {
      let rx = formatBytes(engine.rBytes)
      let tx = formatBytes(engine.wBytes)
      print(
        "[\(timestamp)] 📊 Traffic: ↓\(rx) ↑\(tx) | Live peers: \(engine.numLive) | DERP connections: \(engine.liveDERPs)"
      )
    }

    // Suggested exit node
    if let exitNode = notify.suggestedExitNode {
      print("[\(timestamp)] 🚀 Suggested exit node: \(exitNode)")
    }
  }

  private func stateEmoji(_ state: IPNState) -> String {
    switch state {
    case .noState: return "❓"
    case .inUseOtherUser: return "🔒"
    case .needsLogin: return "🔑"
    case .needsMachineAuth: return "⏳"
    case .stopped: return "⏹️"
    case .starting: return "🔄"
    case .running: return "✅"
    }
  }

  private func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
      value /= 1024
      unitIndex += 1
    }
    if unitIndex == 0 {
      return "\(bytes) B"
    }
    return String(format: "%.1f %@", value, units[unitIndex])
  }
}
