// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation

/// An immutable point-in-time snapshot of the daemon's serve and Funnel configuration,
/// encapsulating the configuration payload, read timestamp, and the daemon's
/// concurrency token (`etag`).
///
/// Use ``TailscaleClient/serveConfigSnapshot()`` to fetch a fresh snapshot, and pass
/// it to ``TailscaleClient/setServeConfig(_:matching:)`` or
/// ``TailscaleClient/updateServeConfig(_:mutate:)`` to perform safe conditional writes.
public struct ServeConfigSnapshot: Sendable, Equatable {
  /// The opaque concurrency token (ETag) returned by the daemon.
  /// Used in the `If-Match` request header on subsequent conditional updates.
  public let etag: String

  /// The local timestamp when this snapshot was captured.
  public let fetchedAt: Date

  /// The decoded serve and Funnel configuration payload at the time of the fetch.
  public let config: ServeConfig

  /// Creates a snapshot instance for tests, previews, or fixtures.
  ///
  /// - Parameters:
  ///   - etag: The opaque concurrency token. Must not be empty.
  ///   - fetchedAt: The timestamp when this snapshot was captured (defaults to current date).
  ///   - config: The serve configuration.
  public init(
    etag: String,
    fetchedAt: Date = Date(),
    config: ServeConfig
  ) {
    self.etag = etag
    self.fetchedAt = fetchedAt
    self.config = config
  }
}
