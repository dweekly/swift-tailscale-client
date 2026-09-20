// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Represents an HTTP streaming response from the LocalAPI prior to body consumption.
///
/// Encapsulates the HTTP status code, response headers, and the underlying stream of body data.
/// Conforms to `AsyncSequence` (yielding framed data chunks or lines) for direct iteration.
public struct StreamingResponse: Sendable, AsyncSequence {
  /// The element type of the streaming response (framed body chunks or lines).
  public typealias Element = Data

  /// The asynchronous iterator type over the streaming response body chunks.
  public typealias AsyncIterator = AsyncThrowingStream<Data, Error>.AsyncIterator

  /// HTTP status code (e.g., 200, 403, 404).
  public let statusCode: Int

  /// HTTP response headers.
  public let headers: [String: String]

  /// Asynchronous stream yielding framed body lines or chunks.
  public let body: AsyncThrowingStream<Data, Error>

  /// The target identifier of the daemon endpoint that produced this response.
  public let targetIdentifier: String?

  /// Creates a new streaming response.
  ///
  /// - Parameters:
  ///   - statusCode: The HTTP status code returned by the daemon.
  ///   - headers: The response headers returned by the daemon.
  ///   - body: The stream yielding response body data chunks or lines.
  public init(
    statusCode: Int,
    headers: [String: String] = [:],
    body: AsyncThrowingStream<Data, Error>
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
    self.targetIdentifier = nil
  }

  /// Creates a new streaming response with target identification.
  ///
  /// - Parameters:
  ///   - statusCode: The HTTP status code returned by the daemon.
  ///   - headers: The response headers returned by the daemon.
  ///   - body: The stream yielding response body data chunks or lines.
  ///   - targetIdentifier: The target identifier of the responding daemon.
  public init(
    statusCode: Int,
    headers: [String: String] = [:],
    body: AsyncThrowingStream<Data, Error>,
    targetIdentifier: String?
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
    self.targetIdentifier = targetIdentifier
  }

  /// Looks up a response header using case-insensitive key comparison.
  ///
  /// - Parameter name: The name of the header to look up.
  /// - Returns: The header value if found, or `nil` otherwise.
  public func value(forHeaderCaseInsensitive name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  /// Creates an async iterator over the response body lines.
  public func makeAsyncIterator() -> AsyncIterator {
    body.makeAsyncIterator()
  }
}
