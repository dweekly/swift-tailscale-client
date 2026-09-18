// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Overflow behavior when a slow consumer causes a streaming buffer to exceed its bounds.
public enum StreamOverflowStrategy: Sendable, Equatable {
  /// Emits a `.lifecycle(.stateGap(reason: "buffer_overflow"))` event and drops stale events.
  case reportGap
  /// Terminates the stream by throwing `TailscaleClientError.streamOverflow`.
  case fail
}

/// Limits on stream queue depth and retained memory to prevent unbounded memory growth.
public struct StreamBufferBounds: Sendable, Equatable {
  /// Maximum number of queued events waiting for consumption. Defaults to 256.
  public var maxEventCount: Int
  /// Maximum bytes retained in the queue. Defaults to 16 MB (16,777,216 bytes).
  public var maxByteCount: Int
  /// Overflow strategy when limits are exceeded.
  public var overflowStrategy: StreamOverflowStrategy

  /// Creates stream buffer limits.
  ///
  /// - Parameters:
  ///   - maxEventCount: Maximum number of events retained before triggering overflow handling.
  ///   - maxByteCount: Maximum retained payload bytes before triggering overflow handling.
  ///   - overflowStrategy: Strategy applied when buffer limits are exceeded.
  public init(
    maxEventCount: Int = 256,
    maxByteCount: Int = 16 * 1024 * 1024,
    overflowStrategy: StreamOverflowStrategy = .reportGap
  ) {
    self.maxEventCount = maxEventCount
    self.maxByteCount = maxByteCount
    self.overflowStrategy = overflowStrategy
  }

  /// Default bounds: 256 events, 16 MB, gap reporting.
  public static let `default` = StreamBufferBounds()

  /// Throwing bounds: 256 events, 16 MB, failing with streamOverflow.
  public static let throwing = StreamBufferBounds(overflowStrategy: .fail)

  /// Unbounded buffer bounds for testing or unrestricted buffers.
  public static let unbounded = StreamBufferBounds(
    maxEventCount: Int.max, maxByteCount: Int.max, overflowStrategy: .reportGap)
}
