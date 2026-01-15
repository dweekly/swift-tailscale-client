// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Captures how the client should connect to the Tailscale daemon.
public enum TailscaleEndpoint: Sendable, Equatable {
  /// Connect via a Unix domain socket at the supplied path.
  case unixSocket(path: String)
  /// Connect via an HTTP server reachable on the local loopback interface.
  case loopback(host: String = "127.0.0.1", port: UInt16)
  /// Use a fully qualified base URL (primarily for testing and custom setups).
  case url(URL)
}

struct LocalAPIDiscovery {
  struct Result: Sendable, Equatable {
    var endpoint: TailscaleEndpoint
    var authToken: String?
    var capabilityVersion: Int
  }

  private let environment: [String: String]
  private let fileExists: (String) -> Bool

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) {
    self.environment = environment
    self.fileExists = fileExists
  }

  func discover() -> Result {
    let capability =
      environment["TAILSCALE_LOCALAPI_CAPABILITY"].flatMap(Int.init) ?? Self.defaultCapability
    let debug = environment["TAILSCALE_DISCOVERY_DEBUG"] == "1"

    // 1. Explicit URL override
    if let urlString = environment["TAILSCALE_LOCALAPI_URL"],
      let url = URL(string: urlString)
    {
      if debug { fputs("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_URL: \(urlString)\n", stderr) }
      return .init(
        endpoint: .url(url), authToken: environment["TAILSCALE_LOCALAPI_AUTHKEY"],
        capabilityVersion: capability)
    }

    // 2. Explicit socket path override
    if let socketPath = environment["TAILSCALE_LOCALAPI_SOCKET"], !socketPath.isEmpty {
      let expanded = Self.expandPath(socketPath)
      if debug {
        fputs("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_SOCKET: \(expanded)\n", stderr)
      }
      return .init(
        endpoint: .unixSocket(path: expanded),
        authToken: environment["TAILSCALE_LOCALAPI_AUTHKEY"],
        capabilityVersion: capability)
    }

    // 3. Explicit port/host override
    if let portString = environment["TAILSCALE_LOCALAPI_PORT"],
      let portValue = UInt16(portString)
    {
      let host = environment["TAILSCALE_LOCALAPI_HOST"] ?? "127.0.0.1"
      if debug {
        fputs("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_PORT: \(host):\(portValue)\n", stderr)
      }
      return .init(
        endpoint: .loopback(host: host, port: portValue),
        authToken: environment["TAILSCALE_LOCALAPI_AUTHKEY"],
        capabilityVersion: capability)
    }

    // 4. Check for Unix sockets FIRST (no Group Container access, no scary popup)
    for candidate in Self.candidateSockets {
      let expanded = Self.expandPath(candidate.path)
      if fileExists(expanded) {
        if debug { fputs("[LocalAPIDiscovery] using Unix socket: \(expanded)\n", stderr) }
        return .init(
          endpoint: .unixSocket(path: expanded),
          authToken: candidate.authToken,
          capabilityVersion: capability)
      }
    }

    // 5. macOS App Store GUI loopback (requires Group Container access - may trigger popup)
    #if os(macOS)
      if let mac = MacClientInfo().locateSameUserProof() {
        if debug {
          let tokenPreview = mac.token.prefix(8)
          fputs(
            "[LocalAPIDiscovery] using macOS loopback port=\(mac.port) token=\(tokenPreview)…\n",
            stderr)
        }
        return .init(
          endpoint: .loopback(host: "127.0.0.1", port: mac.port),
          authToken: mac.token,
          capabilityVersion: capability)
      }
    #endif

    // 6. Final fallback to default socket path
    if debug {
      fputs(
        "[LocalAPIDiscovery] falling back to default socket: \(Self.defaultSocketPath)\n", stderr)
    }
    return .init(
      endpoint: .unixSocket(path: Self.expandPath(Self.defaultSocketPath)),
      authToken: nil,
      capabilityVersion: capability)
  }

  private func defaultSocketFallback() -> (path: String, authToken: String?) {
    for candidate in Self.candidateSockets {
      let expanded = Self.expandPath(candidate.path)
      if fileExists(expanded) {
        return (expanded, candidate.authToken)
      }
    }
    return (Self.expandPath(Self.defaultSocketPath), nil)
  }

  private static func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
  }

  private static let defaultCapability = 1
  private static let defaultSocketPath = "/var/run/tailscale/tailscaled.sock"

  private static let candidateSockets: [(path: String, authToken: String?)] = [
    // Homebrew tailscaled (no Group Container access needed!)
    ("/var/run/tailscaled.socket", nil),
    // System Extension (MDM-managed)
    ("/Library/Tailscale/Data/tailscaled.sock", nil),
    // User-level tailscaled
    ("~/Library/Application Support/Tailscale/tailscaled.sock", nil),
    // Linux/older macOS convention
    ("/var/run/tailscale/tailscaled.sock", nil),
  ]
}
