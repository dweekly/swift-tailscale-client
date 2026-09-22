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
  /// Captures how the LocalAPI endpoint was resolved, governing recovery and re-discovery behavior.
  public var endpointSource: EndpointSource

  /// An opaque identifier representing the target endpoint of this configuration,
  /// used for target-binding validation across snapshots.
  public var targetIdentifier: String {
    endpoint.description
  }

  /// The default for ``capabilityVersion``, pinned to a tested upstream
  /// revision — never bumped to "latest" without compatibility evidence.
  ///
  /// Provenance: `tailcfg.CurrentCapabilityVersion` is **148** at the
  /// immutable `tailscale/tailscale` commit recorded in
  /// `Documentation/endpoints.json` (`upstream_provenance.revision`,
  /// currently `7bf76690f09d…`), the same revision our wire models were
  /// verified against; `Scripts/verify-upstream-maturity.py` re-checks the
  /// constant against that exact commit in CI. Compatibility evidence and
  /// the scope of the upstream review are recorded in
  /// `Documentation/COMPATIBILITY-148.md`.
  ///
  /// Update procedure: advance the pinned commit in the manifest, re-verify
  /// the upstream constant there, re-check any capability-gated LocalAPI
  /// behavior against our models, run the matrix, and update this constant —
  /// in that order (CI enforces the agreement).
  public static let defaultCapabilityVersion = 148

  /// This package's own release version, surfaced in
  /// ``TailscaleClient/versionDiagnostics()``. Kept in sync with the
  /// CHANGELOG by `Scripts/check-release-consistency.sh`.
  public static let packageVersion = "1.0.0"

  /// Creates a new configuration with explicit settings.
  ///
  /// - Parameters:
  ///   - endpoint: The connection endpoint (Unix socket, TCP loopback, or custom URL).
  ///   - authToken: Optional authentication token for TCP connections.
  ///   - capabilityVersion: Capability version to advertise to the daemon
  ///     (defaults to ``defaultCapabilityVersion``).
  ///   - requestTimeout: Per-request deadline (defaults to 30 seconds; nil disables).
  ///   - transport: Transport implementation for executing requests (defaults to URLSessionTailscaleTransport).
  ///   - endpointSource: Origin and recovery policy of the endpoint (defaults to `.pinned(endpoint)`).
  public init(
    endpoint: TailscaleEndpoint,
    authToken: String?,
    capabilityVersion: Int = TailscaleClientConfiguration.defaultCapabilityVersion,
    requestTimeout: Duration? = .seconds(30),
    transport: any TailscaleTransport = URLSessionTailscaleTransport(),
    endpointSource: EndpointSource? = nil
  ) {
    self.endpoint = endpoint
    self.authToken = authToken
    self.capabilityVersion = capabilityVersion
    self.requestTimeout = requestTimeout
    self.transport = transport
    self.endpointSource = endpointSource ?? .pinned(endpoint)
  }

  /// Internal initializer for automatic discovery results.
  init(
    discovery: LocalAPIDiscovery,
    result: LocalAPIDiscovery.Result,
    requestTimeout: Duration? = .seconds(30),
    transport: any TailscaleTransport = URLSessionTailscaleTransport()
  ) {
    self.endpoint = result.endpoint
    self.authToken = result.authToken
    self.capabilityVersion = result.capabilityVersion
    self.requestTimeout = requestTimeout
    self.transport = transport
    self.endpointSource = .automatic(discovery)
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
  /// 3. macOS standalone `.pkg` app (`/Library/Tailscale/ipnport` symlink)
  /// 4. Default fallback socket path
  public static var `default`: TailscaleClientConfiguration {
    `default`(allowMacOSAppStoreDiscovery: false)
  }

  /// Returns a configuration with explicit control over macOS App Store discovery and transport injection.
  ///
  /// - Parameters:
  ///   - allowMacOSAppStoreDiscovery: If `true`, enables discovery of the macOS App Store GUI's
  ///     loopback API by scanning Group Containers. **WARNING:** This will trigger a macOS TCC permission
  ///     popup asking the user to allow access to another app's data. Only enable this if:
  ///     - Your users have the App Store version of Tailscale (not Homebrew/standalone)
  ///     - You have explained to users why this permission is needed
  ///     - Unix socket discovery has failed
  ///   - transport: The transport used to execute HTTP requests (defaults to URLSessionTailscaleTransport).
  ///
  /// - Returns: A configuration suitable for connecting to the LocalAPI.
  public static func `default`(
    allowMacOSAppStoreDiscovery: Bool = false,
    transport: any TailscaleTransport = URLSessionTailscaleTransport()
  ) -> TailscaleClientConfiguration {
    let discovery = LocalAPIDiscovery(
      allowMacOSAppStoreDiscovery: allowMacOSAppStoreDiscovery
    )
    let result = discovery.discover()
    return TailscaleClientConfiguration(
      discovery: discovery,
      result: result,
      requestTimeout: .seconds(30),
      transport: transport
    )
  }

  /// Asynchronously discovers and constructs a configuration, executing candidate probes off the calling actor.
  ///
  /// - Parameters:
  ///   - allowMacOSAppStoreDiscovery: Whether to opt into macOS App Store GUI discovery.
  ///   - requestTimeout: Per-request deadline (defaults to 30 seconds).
  ///   - transport: The transport used to execute HTTP requests (defaults to URLSessionTailscaleTransport).
  /// - Returns: A discovered client configuration marked `.automatic`.
  public static func discover(
    allowMacOSAppStoreDiscovery: Bool = false,
    requestTimeout: Duration? = .seconds(30),
    transport: any TailscaleTransport = URLSessionTailscaleTransport()
  ) async throws -> TailscaleClientConfiguration {
    let discovery = LocalAPIDiscovery(
      allowMacOSAppStoreDiscovery: allowMacOSAppStoreDiscovery
    )
    let result = try await discovery.discoverAsync()
    return TailscaleClientConfiguration(
      discovery: discovery,
      result: result,
      requestTimeout: requestTimeout,
      transport: transport
    )
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
      + "capabilityVersion: \(capabilityVersion), requestTimeout: \(timeout), endpointSource: \(endpointSource))"
  }

  /// A textual description of the configuration suitable for debugging.
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
        "endpointSource": String(describing: endpointSource),
      ],
      displayStyle: .struct)
  }
}
