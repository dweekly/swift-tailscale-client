// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

// MARK: - Stable-parity surface (upstream-readiness issue 04)
//
// Every method here wraps a LocalAPI operation Tailscale explicitly documents
// as stable in `client/local` — except `checkUDPGROForwarding()`, which
// upstream annotates unstable and which ships as supported normalization.
// Wire shapes and annotations were verified against upstream source at the
// pinned revision in Documentation/endpoints.json
// (Scripts/verify-upstream-maturity.py re-checks them in CI).

/// The IP protocol scope for a protocol-specific whois lookup.
public enum WhoIsIPProtocol: String, Sendable {
  case tcp
  case udp
}

extension TailscaleClient {
  /// Looks up the owner of `address` (IP or `ip:port`) for a specific IP
  /// protocol. Upstream: `WhoIsProto` (stable).
  ///
  /// - Throws: ``TailscaleClientError/peerNotFound(endpoint:)`` when no peer
  ///   matches — mirroring upstream's typed `ErrPeerNotFound`.
  public func whois(address: String, protocol proto: WhoIsIPProtocol) async throws
    -> WhoIsResponse
  {
    try await whoisRequest(queryItems: [
      URLQueryItem(name: "proto", value: proto.rawValue),
      URLQueryItem(name: "addr", value: address),
    ])
  }

  /// Looks up the owner of a WireGuard node public key
  /// (`"nodekey:<64 hex digits>"`). Upstream: `WhoIsNodeKey` (stable).
  ///
  /// - Throws: ``TailscaleClientError/peerNotFound(endpoint:)`` when no peer
  ///   matches.
  public func whois(nodeKey: String) async throws -> WhoIsResponse {
    try await whoisRequest(queryItems: [URLQueryItem(name: "addr", value: nodeKey)])
  }

  /// Like ``whois(address:)`` but scopes the returned capability map to
  /// capabilities that apply to the given destination IP (a VIP service
  /// address, the node's own address, or any routable IP).
  /// Upstream: `WhoIsForIP` (stable).
  public func whois(address: String, scopedToDestination dstIP: String) async throws
    -> WhoIsResponse
  {
    try await whoisRequest(queryItems: [
      URLQueryItem(name: "addr", value: address),
      URLQueryItem(name: "dst_ip", value: dstIP),
    ])
  }

  /// Like ``whois(address:)`` but scopes the returned capability map to a
  /// named Tailscale Service (e.g. `"svc:name"`).
  /// Upstream: `WhoIsForService` (stable).
  public func whois(address: String, forService serviceName: String) async throws
    -> WhoIsResponse
  {
    try await whoisRequest(queryItems: [
      URLQueryItem(name: "addr", value: address),
      URLQueryItem(name: "svc_name", value: serviceName),
    ])
  }

  private func whoisRequest(queryItems: [URLQueryItem]) async throws -> WhoIsResponse {
    let endpoint = "/localapi/v0/whois"
    let request = TailscaleRequest(path: endpoint, queryItems: queryItems)
    return try await performRequest(request, endpoint: endpoint, peerLookup: true)
  }

  /// Asks the daemon whether a newer Tailscale client is available.
  /// Upstream: `CheckUpdate` (stable), `GET /localapi/v0/update/check`.
  ///
  /// This only *reports* the daemon's update information — nothing is
  /// installed. Daemons built without the client-update feature surface
  /// ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.
  public func checkUpdate() async throws -> ClientVersionStatus {
    let endpoint = "/localapi/v0/update/check"
    let request = TailscaleRequest(path: endpoint)
    return try await performRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "clientupdate")
  }

  /// **Administrative:** disconnects the daemon from the control plane
  /// until it is restarted or reconnected by policy.
  /// Upstream: `DisconnectControl` (stable), used to gracefully drain
  /// highly-available subnet-router or app-connector replicas before
  /// shutdown — data-plane connections keep working, but the node stops
  /// receiving netmap/policy updates.
  ///
  /// > Warning: This changes live daemon behavior for every user of the
  /// > machine. Never call it casually, and never in tests against a real
  /// > daemon (this package exercises it with wire-shape unit tests only).
  public func disconnectControl() async throws {
    let endpoint = "/localapi/v0/disconnect-control"
    let request = TailscaleRequest(method: "POST", path: endpoint)
    _ = try await performRawRequest(request, endpoint: endpoint)
  }

  /// Subnet-router/exit-node performance preflight: checks whether UDP GRO
  /// forwarding is configured on the main interface (a Linux optimization).
  /// Upstream: `CheckUDPGROForwarding` — annotated **unstable** upstream;
  /// this wrapper is supported normalization, not a stable-parity item.
  ///
  /// Non-Linux daemons and older builds surface
  /// ``TailscaleClientError/endpointUnavailable(endpoint:feature:)``.
  public func checkUDPGROForwarding() async throws -> IPForwardingCheck {
    let endpoint = "/localapi/v0/check-udp-gro-forwarding"
    let request = TailscaleRequest(path: endpoint)
    return try await performRequest(request, endpoint: endpoint, optionalEndpoint: true)
  }

  /// Logs a bug-report marker in the daemon log and returns the marker ID
  /// to include in support requests.
  /// Upstream: `BugReport` (stable), `POST /localapi/v0/bugreport`.
  ///
  /// This is the supported home of the operation;
  /// `experimental.bugreport(note:diagnose:record:)` remains for the
  /// diagnose/record knobs, which follow upstream's debug tier.
  public func bugReport(note: String? = nil) async throws -> String {
    let endpoint = "/localapi/v0/bugreport"
    var queryItems: [URLQueryItem] = []
    if let note, !note.isEmpty {
      queryItems.append(URLQueryItem(name: "note", value: note))
    }
    let request = TailscaleRequest(method: "POST", path: endpoint, queryItems: queryItems)
    let marker = try await performRawRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "debug")
    return marker.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
