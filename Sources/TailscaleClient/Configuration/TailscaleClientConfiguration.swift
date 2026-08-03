// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Configuration options controlling how `TailscaleClient` communicates with the LocalAPI.
public struct TailscaleClientConfiguration: Sendable {
  /// The resolved connection endpoint.
  public var endpoint: TailscaleEndpoint
  /// Optional authentication token (macOS GUI variants typically require this when using TCP fallback).
  public var authToken: String?
  /// Capability version sent as the `Tailscale-Cap` header on every request.
  ///
  /// This advertises which LocalAPI capability level the client understands
  /// (upstream: `tailcfg.CurrentCapabilityVersion`). The default of
  /// ``defaultCapabilityVersion`` is pinned to a *tested* upstream revision —
  /// see that constant for provenance and the update procedure. Override via
  /// this property or the `TAILSCALE_LOCALAPI_CAPABILITY` environment
  /// variable when you need different daemon behavior.
  public var capabilityVersion: Int
  /// Deadline applied to each unary request and to establishing a streaming
  /// connection (not to the lifetime of an established stream). `nil` disables
  /// the client-side deadline. Defaults to 30 seconds.
  public var requestTimeout: Duration?
  /// Transport responsible for executing HTTP requests. Defaults to the built-in implementation.
  public var transport: any TailscaleTransport

  /// The default for ``capabilityVersion``, pinned to a tested upstream
  /// revision — never bumped to "latest" without compatibility evidence.
  ///
  /// Provenance: `tailcfg.CurrentCapabilityVersion` is **144** at the
  /// immutable `tailscale/tailscale` commit recorded in
  /// `Documentation/endpoints.json` (`upstream_provenance.revision`,
  /// currently `4c4d1c35f83a…`), the same revision our wire models were
  /// verified against; `Scripts/verify-upstream-maturity.py` re-checks the
  /// constant against that exact commit in CI. Compatibility evidence: the
  /// full integration suite passes with this value against the hermetic
  /// daemon matrix (current stable, previous stable 1.96.4, unstable) and a
  /// real tailnet daemon.
  ///
  /// Update procedure: advance the pinned commit in the manifest, re-verify
  /// the upstream constant there, re-check any capability-gated LocalAPI
  /// behavior against our models, run the matrix, and update this constant —
  /// in that order (CI enforces the agreement).
  public static let defaultCapabilityVersion = 144

  /// This package's own release version, surfaced in
  /// ``TailscaleClient/versionDiagnostics()``. Kept in sync with the
  /// CHANGELOG by `Scripts/check-release-consistency.sh`.
  public static let packageVersion = "0.10.0"

  /// Creates a new configuration with explicit settings.
  ///
  /// - Parameters:
  ///   - endpoint: The connection endpoint (Unix socket, TCP loopback, or custom URL).
  ///   - authToken: Optional authentication token for TCP connections.
  ///   - capabilityVersion: Capability version to advertise to the daemon
  ///     (defaults to ``defaultCapabilityVersion``).
  ///   - requestTimeout: Per-request deadline (defaults to 30 seconds; nil disables).
  ///   - transport: Transport implementation for executing requests (defaults to URLSessionTailscaleTransport).
  public init(
    endpoint: TailscaleEndpoint,
    authToken: String?,
    capabilityVersion: Int = TailscaleClientConfiguration.defaultCapabilityVersion,
    requestTimeout: Duration? = .seconds(30),
    transport: any TailscaleTransport = URLSessionTailscaleTransport()
  ) {
    self.endpoint = endpoint
    self.authToken = authToken
    self.capabilityVersion = capabilityVersion
    self.requestTimeout = requestTimeout
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

extension TailscaleClientConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
  /// Never includes the auth token: printing a configuration in logs or a
  /// debugger must not leak credential material.
  public var description: String {
    let token = authToken == nil ? "nil" : "<redacted>"
    let timeout = requestTimeout.map { "\($0)" } ?? "nil"
    return
      "TailscaleClientConfiguration(endpoint: \(endpoint), authToken: \(token), "
      + "capabilityVersion: \(capabilityVersion), requestTimeout: \(timeout))"
  }

  public var debugDescription: String { description }
}

extension TailscaleClientConfiguration: CustomReflectable {
  /// `dump(_:)` and `Mirror` follow this instead of the stored properties,
  /// so the auth token cannot surface through reflection either — including
  /// when a configuration is nested inside a reflected container.
  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "endpoint": endpoint,
        "authToken": authToken == nil ? "nil" : "<redacted>",
        "capabilityVersion": capabilityVersion,
        "requestTimeout": requestTimeout.map { "\($0)" } ?? "nil",
        "transport": String(describing: type(of: transport)),
      ],
      displayStyle: .struct)
  }
}
