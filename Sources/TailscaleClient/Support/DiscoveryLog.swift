// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Shared sink for discovery debug logging (`TAILSCALE_DISCOVERY_DEBUG=1`).
///
/// Two jobs:
/// 1. Route every diagnostic line through one place so tests can capture the
///    complete output and prove no secret material appears in it.
/// 2. Own the redaction helpers used before *any* value derived from a
///    credential (including sameuserproof file paths, whose **filename embeds
///    the auth token**) reaches a log line.
enum DiscoveryLog {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var _sink: (@Sendable (String) -> Void)?

  /// Test hook: when set, lines go to the closure instead of stderr.
  static var sink: (@Sendable (String) -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _sink
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _sink = newValue
    }
  }

  /// Emits one diagnostic line. Callers are responsible for redacting
  /// secret-derived values first (see `redactedProofPath(_:)`).
  static func emit(_ message: String) {
    if let sink {
      sink(message)
      return
    }
    // Write to stderr via fd 2 directly: the C `stderr` global is not
    // concurrency-safe under Swift 6 strict concurrency on Glibc.
    let bytes = Array((message + "\n").utf8)
    bytes.withUnsafeBufferPointer { buffer in
      _ = write(2, buffer.baseAddress, buffer.count)
    }
  }

  /// Masks the token component of a `sameuserproof-<port>-<token>` path,
  /// keeping the directory and port (the useful, non-secret provenance).
  /// Paths that don't look like proof files pass through unchanged.
  static func redactedProofPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    guard name.hasPrefix("sameuserproof-") else { return path }
    let components = name.split(separator: "-")
    guard components.count >= 3 else {
      return url.deletingLastPathComponent().appendingPathComponent("sameuserproof-…").path
    }
    let masked = "\(components[0])-\(components[1])-…"
    return url.deletingLastPathComponent().appendingPathComponent(masked).path
  }
}
