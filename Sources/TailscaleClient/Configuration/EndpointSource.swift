// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Captures how the LocalAPI endpoint was resolved, governing recovery and re-discovery behavior.
public enum EndpointSource: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// Resolved automatically via `LocalAPIDiscovery`.
  ///
  /// Automatically re-discovers port and credentials on daemon restart (e.g. when the loopback
  /// port or proof token changes).
  case automatic(LocalAPIDiscovery)

  /// Explicitly configured by the caller to target a fixed endpoint.
  ///
  /// Strictly targets the specified endpoint and never performs dynamic re-discovery.
  case pinned(TailscaleEndpoint)

  /// A textual description of the endpoint source.
  public var description: String {
    switch self {
    case .automatic:
      return "EndpointSource.automatic"
    case .pinned(let endpoint):
      return "EndpointSource.pinned(\(endpoint))"
    }
  }

  /// A textual description of the endpoint source suitable for debugging.
  public var debugDescription: String { description }
}
