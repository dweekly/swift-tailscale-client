// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Configuration options controlling how `TailscaleClient` communicates with the LocalAPI.
public struct TailscaleClientConfiguration: Sendable {
  /// The resolved connection endpoint.
  public var endpoint: TailscaleEndpoint
  /// Optional authentication token (macOS GUI variants typically require this when using TCP fallback).
  public var authToken: String?
  /// Capability version advertised to the daemon. This should track `tailcfg.CurrentCapabilityVersion`.
  public var capabilityVersion: Int
  /// Transport responsible for executing HTTP requests. Defaults to the built-in implementation.
  public var transport: any TailscaleTransport

  /// Creates a new configuration with explicit settings.
  ///
  /// - Parameters:
  ///   - endpoint: The connection endpoint (Unix socket, TCP loopback, or custom URL).
  ///   - authToken: Optional authentication token for TCP connections.
  ///   - capabilityVersion: Capability version to advertise to the daemon (defaults to 1).
  ///   - transport: Transport implementation for executing requests (defaults to URLSessionTailscaleTransport).
  public init(
    endpoint: TailscaleEndpoint,
    authToken: String?,
    capabilityVersion: Int,
    transport: any TailscaleTransport = URLSessionTailscaleTransport()
  ) {
    self.endpoint = endpoint
    self.authToken = authToken
    self.capabilityVersion = capabilityVersion
    self.transport = transport
  }

  /// Returns a configuration discovered from the current process environment and platform defaults.
  public static var `default`: TailscaleClientConfiguration {
    let discovery = LocalAPIDiscovery().discover()
    return TailscaleClientConfiguration(
      endpoint: discovery.endpoint,
      authToken: discovery.authToken,
      capabilityVersion: discovery.capabilityVersion)
  }
}
