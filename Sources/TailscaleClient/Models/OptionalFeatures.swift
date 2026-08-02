// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// The optional features a tailscaled build was compiled with, as reported by
/// `POST /localapi/v0/debug-optional-features`.
///
/// Since Tailscale modularized the daemon, endpoint availability depends on
/// build flags, not just the version: a size-trimmed daemon returns 404 for
/// endpoints that exist in other builds of the same release. Use
/// ``TailscaleClient/daemonFeatures()`` to probe before relying on optional
/// surfaces.
///
/// Upstream: `apitype.OptionalFeatures`. Features compiled out may be absent
/// from the map rather than present-but-false.
public struct OptionalFeatures: Codable, Sendable, Equatable {
  /// Optional feature names mapped to whether they are enabled.
  public var features: [String: Bool]

  /// Creates an instance for tests, previews, or fixtures.
  public init(features: [String: Bool] = [:]) {
    self.features = features
  }

  /// Whether the named feature is present and enabled. Absent features
  /// report `false`.
  public func isEnabled(_ name: String) -> Bool {
    features[name] ?? false
  }

  private enum CodingKeys: String, CodingKey {
    case features = "Features"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    features = try container.decodeIfPresent([String: Bool].self, forKey: .features) ?? [:]
  }
}
