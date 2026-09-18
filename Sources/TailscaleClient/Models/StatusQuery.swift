// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Options that influence how `/localapi/v0/status` responds.
public struct StatusQuery: Sendable, Equatable {
  /// Include peer information in the response. Defaults to the daemon's default (currently true).
  public var includePeers: Bool?

  /// Creates a status query configuration.
  ///
  /// - Parameter includePeers: Whether to include peer nodes in the status response.
  public init(includePeers: Bool? = nil) {
    self.includePeers = includePeers
  }

  var queryItems: [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let includePeers {
      items.append(URLQueryItem(name: "peers", value: includePeers ? "true" : "false"))
    }
    return items
  }
}

extension StatusQuery {
  /// The default status query options, using daemon defaults.
  public static var `default`: StatusQuery { StatusQuery() }
}
