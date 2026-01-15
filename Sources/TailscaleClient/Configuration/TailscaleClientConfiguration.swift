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
  ///
  /// By default, this does NOT attempt to access the macOS App Store GUI's Group Container,
  /// which would trigger a TCC permission popup. Use `default(allowMacOSAppStoreDiscovery:)`
  /// if you need to connect to the App Store version of Tailscale.
  ///
  /// Discovery order:
  /// 1. Environment variable overrides (`TAILSCALE_LOCALAPI_URL`, `TAILSCALE_LOCALAPI_SOCKET`, etc.)
  /// 2. Unix domain sockets (Homebrew: `/var/run/tailscaled.socket`, System: `/Library/Tailscale/Data/tailscaled.sock`)
  /// 3. Default fallback socket path
  public static var `default`: TailscaleClientConfiguration {
    `default`(allowMacOSAppStoreDiscovery: false)
  }

  /// Returns a configuration with explicit control over macOS App Store discovery.
  ///
  /// - Parameter allowMacOSAppStoreDiscovery: If `true`, enables discovery of the macOS App Store GUI's
  ///   loopback API by scanning Group Containers. **WARNING:** This will trigger a macOS TCC permission
  ///   popup asking the user to allow access to another app's data. Only enable this if:
  ///   - Your users have the App Store version of Tailscale (not Homebrew/standalone)
  ///   - You have explained to users why this permission is needed
  ///   - Unix socket discovery has failed
  ///
  ///   When `false` (the default), only Unix domain sockets and environment variable overrides are used,
  ///   which works with Homebrew (`brew install tailscale`) and standalone `tailscaled` installations
  ///   without any permission popups.
  ///
  /// - Returns: A configuration suitable for connecting to the LocalAPI.
  public static func `default`(allowMacOSAppStoreDiscovery: Bool) -> TailscaleClientConfiguration {
    let discovery = LocalAPIDiscovery(
      allowMacOSAppStoreDiscovery: allowMacOSAppStoreDiscovery
    ).discover()
    return TailscaleClientConfiguration(
      endpoint: discovery.endpoint,
      authToken: discovery.authToken,
      capabilityVersion: discovery.capabilityVersion)
  }
}
