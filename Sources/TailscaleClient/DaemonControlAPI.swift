// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

// MARK: - Daemon lifecycle & services (always-on handlers)

extension TailscaleClient {
  /// Returns the Tailscale Services (VIP services) visible to this node,
  /// keyed by service name (`"svc:dns-label"`).
  ///
  /// Upstream: `GetServices` over `GET /localapi/v0/services` (no upstream
  /// maturity annotation — assume unstable; this wrapper is supported
  /// normalization). The daemon answers `503` when it has no netmap yet
  /// (surfaced as ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)``);
  /// daemons that predate the endpoint surface
  /// ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.
  public func services() async throws -> [String: ServiceDetails] {
    let endpoint = "/localapi/v0/services"
    let request = TailscaleRequest(path: endpoint)
    return try await performRequest(request, endpoint: endpoint, optionalEndpoint: true)
  }

  /// Asks tailscaled to exit gracefully.
  ///
  /// > Warning: **Destructive.** The daemon terminates: every user and
  /// > process on this machine loses Tailscale connectivity until something
  /// > restarts it (launchd/systemd may or may not). Never call this
  /// > casually — this package exercises it with wire-shape unit tests
  /// > only, never against live daemons.
  ///
  /// The daemon requires write access **and** the `AllowTailscaledRestart`
  /// policy; otherwise it answers `403`, surfaced as
  /// ``TailscaleClientError/permissionDenied(body:endpoint:)``.
  ///
  /// Upstream: `ShutdownTailscaled` over `POST /localapi/v0/shutdown`
  /// (annotated **unstable** upstream; supported normalization here).
  /// Daemons that predate the endpoint surface
  /// ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.
  public func shutdownTailscaled() async throws {
    let endpoint = "/localapi/v0/shutdown"
    let request = TailscaleRequest(method: "POST", path: endpoint)
    _ = try await performRawRequest(request, endpoint: endpoint, optionalEndpoint: true)
  }
}
