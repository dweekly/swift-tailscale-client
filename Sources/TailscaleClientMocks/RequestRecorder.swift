// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClient

/// Collects the requests a `MockTransport` handler receives, for assertion in tests.
///
/// ```swift
/// let recorder = RequestRecorder()
/// let transport = MockTransport { request, _ in
///     await recorder.record(request: request)
///     return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
/// }
/// // ... exercise the client ...
/// let captured = await recorder.requests
/// ```
public actor RequestRecorder {
  private var storage: [TailscaleRequest] = []

  public init() {}

  /// Appends a request to the recording.
  public func record(request: TailscaleRequest) {
    storage.append(request)
  }

  /// All requests recorded so far, in arrival order.
  public var requests: [TailscaleRequest] {
    storage
  }
}
