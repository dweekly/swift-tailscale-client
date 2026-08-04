// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// A Tailscale Service (VIP service) visible to this node, from
/// `GET /localapi/v0/services`.
///
/// Upstream: `tailcfg.ServiceDetails`.
public struct ServiceDetails: Codable, Sendable, Equatable {
  /// The service name, of the form `"svc:dns-label"`.
  public var name: String

  /// Optional human-readable label; clients fall back to ``name`` when empty.
  public var displayName: String?

  /// The IP addresses (IPv4 and IPv6) assigned to this service.
  public var addresses: [String]

  /// The protocol/port combinations the service accepts, in upstream's
  /// `ProtoPortRange` text form (e.g. `"tcp:443"`, `"udp:53-54"`, `"*"` —
  /// a bare form like `"80"` means TCP+UDP+ICMP on that port).
  public var ports: [String]

  /// Optional actions describing how a client may interact with the
  /// service. Ignore actions whose ``ServiceAction/type`` you don't
  /// recognize (upstream's explicit guidance); an empty list means clients
  /// may infer default interactions from ``ports``.
  public var actions: [ServiceAction]

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    name: String,
    displayName: String? = nil,
    addresses: [String] = [],
    ports: [String] = [],
    actions: [ServiceAction] = []
  ) {
    self.name = name
    self.displayName = displayName
    self.addresses = addresses
    self.ports = ports
    self.actions = actions
  }

  private enum CodingKeys: String, CodingKey {
    case name = "Name"
    case displayName = "DisplayName"
    case addresses = "Addrs"
    case ports = "Ports"
    case actions = "Actions"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
    ports = try container.decodeIfPresent([String].self, forKey: .ports) ?? []
    actions = try container.decodeIfPresent([ServiceAction].self, forKey: .actions) ?? []
  }
}

/// An action a client can invoke for a ``ServiceDetails``.
///
/// Upstream: `tailcfg.ServiceAction`. `type` is an open slug set
/// (e.g. `"aws-s3"`, `"cockroach"`, `"postgres"`); ignore types you don't
/// recognize.
public struct ServiceAction: Codable, Sendable, Equatable {
  /// The action's identifier slug; drives icon selection and client
  /// application matching. Open set — kept as a raw string on purpose.
  public var type: String

  /// The target TCP port; matches one of the concrete (non-range) TCP
  /// ports in the enclosing ``ServiceDetails/ports``.
  public var port: UInt16

  /// Optional human-readable label for menus with multiple actions.
  public var displayName: String?

  /// Optional metadata keyed by upstream `ServiceActionAttribute` names
  /// (e.g. `"tailscale.com/cap/web-client-url"`); values are arbitrary JSON.
  public var attributes: [String: JSONValue]?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    type: String,
    port: UInt16,
    displayName: String? = nil,
    attributes: [String: JSONValue]? = nil
  ) {
    self.type = type
    self.port = port
    self.displayName = displayName
    self.attributes = attributes
  }

  private enum CodingKeys: String, CodingKey {
    case type = "Type"
    case port = "Port"
    case displayName = "DisplayName"
    case attributes = "Attributes"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 0
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    attributes = try container.decodeIfPresent([String: JSONValue].self, forKey: .attributes)
  }
}
