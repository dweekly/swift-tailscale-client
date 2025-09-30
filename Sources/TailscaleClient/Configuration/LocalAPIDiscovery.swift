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

    if let urlString = environment["TAILSCALE_LOCALAPI_URL"],
      let url = URL(string: urlString)
    {
      return .init(
        endpoint: .url(url), authToken: environment["TAILSCALE_LOCALAPI_AUTHKEY"],
        capabilityVersion: capability)
    }

    if let socketPath = environment["TAILSCALE_LOCALAPI_SOCKET"], !socketPath.isEmpty {
      return .init(
        endpoint: .unixSocket(path: Self.expandPath(socketPath)),
        authToken: environment["TAILSCALE_LOCALAPI_AUTHKEY"],
        capabilityVersion: capability)
    }

    if let portString = environment["TAILSCALE_LOCALAPI_PORT"],
      let portValue = UInt16(portString)
    {
      let host = environment["TAILSCALE_LOCALAPI_HOST"] ?? "127.0.0.1"
      return .init(
        endpoint: .loopback(host: host, port: portValue),
        authToken: environment["TAILSCALE_LOCALAPI_AUTHKEY"],
        capabilityVersion: capability)
    }

    #if os(macOS)
      if let mac = MacClientInfo().locateSameUserProof() {
        if ProcessInfo.processInfo.environment["TAILSCALE_DISCOVERY_DEBUG"] == "1" {
          let tokenPreview = mac.token.prefix(8)
          fputs(
            "[LocalAPIDiscovery] using mac loopback port=\(mac.port) token=\(tokenPreview)…\n",
            stderr)
        }
        return .init(
          endpoint: .loopback(host: "127.0.0.1", port: mac.port),
          authToken: mac.token,
          capabilityVersion: capability)
      }
    #endif

    let fallback = defaultSocketFallback()
    return .init(
      endpoint: .unixSocket(path: fallback.path),
      authToken: fallback.authToken,
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
    ("/Library/Tailscale/Data/tailscaled.sock", nil),
    ("~/Library/Application Support/Tailscale/tailscaled.sock", nil),
    ("/var/run/tailscale/tailscaled.sock", nil),
  ]
}
