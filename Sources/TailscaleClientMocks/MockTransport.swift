// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import TailscaleClient

/// A scriptable `TailscaleTransport` for testing code that uses `TailscaleClient`
/// without a running daemon.
///
/// Inject a `MockTransport` through `TailscaleClientConfiguration` and script the
/// responses your test needs:
///
/// ```swift
/// let transport = MockTransport { request, _ in
///     TailscaleResponse(statusCode: 200, data: fixtureJSON)
/// }
/// let configuration = TailscaleClientConfiguration(
///     endpoint: .url(URL(string: "http://mock.local")!),
///     authToken: nil,
///     capabilityVersion: 1,
///     transport: transport)
/// let client = TailscaleClient(configuration: configuration)
/// ```
///
/// Streaming endpoints are scripted the same way, either with a custom stream
/// handler or with `scriptedStream(_:)` for the common line-sequence case.
public struct MockTransport: TailscaleTransport {
  /// Produces the response for a unary request.
  public typealias Handler =
    @Sendable (TailscaleRequest, TailscaleClientConfiguration) async throws -> TailscaleResponse

  /// Produces the line stream for a streaming request.
  public typealias StreamHandler =
    @Sendable (TailscaleRequest, TailscaleClientConfiguration) async throws
    -> AsyncThrowingStream<Data, Error>

  private let handler: Handler?
  private let streamHandler: StreamHandler?

  /// Creates a transport that serves unary requests; streaming requests throw
  /// `TailscaleTransportError.unimplemented`.
  ///
  /// This is the only single-closure initializer so trailing-closure syntax
  /// stays unambiguous; build streaming-only transports with
  /// ``streaming(_:)``, ``scriptedStream(_:)``, or ``scriptedStreams(_:)``.
  public init(handler: @escaping Handler) {
    self.handler = handler
    self.streamHandler = nil
  }

  /// Creates a transport that serves both unary and streaming requests.
  public init(handler: @escaping Handler, streaming: @escaping StreamHandler) {
    self.handler = handler
    self.streamHandler = streaming
  }

  private init(handler: Handler?, streamHandler: StreamHandler?) {
    self.handler = handler
    self.streamHandler = streamHandler
  }

  /// A transport that serves streaming requests via `streamHandler`; unary
  /// requests throw `TailscaleTransportError.unimplemented`.
  public static func streaming(_ streamHandler: @escaping StreamHandler) -> MockTransport {
    MockTransport(handler: nil, streamHandler: streamHandler)
  }

  public func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
    async throws -> TailscaleResponse
  {
    guard let handler else { throw TailscaleTransportError.unimplemented }
    return try await handler(request, configuration)
  }

  public func sendStreaming(
    _ request: TailscaleRequest, configuration: TailscaleClientConfiguration
  ) async throws -> AsyncThrowingStream<Data, Error> {
    guard let streamHandler else { throw TailscaleTransportError.unimplemented }
    return try await streamHandler(request, configuration)
  }
}

/// One step in a scripted stream, consumed in order by `MockTransport.scriptedStream(_:)`.
public enum MockStreamEvent: Sendable {
  /// Yield one line of data (for the IPN bus, one JSON-encoded notification).
  case line(Data)
  /// Pause before the next event, e.g. to exercise consumer timing.
  case delay(Duration)
  /// Terminate the stream with an error, as a dropped daemon connection would.
  case failure(any Error & Sendable)

  /// Convenience for a UTF-8 JSON line.
  public static func jsonLine(_ json: String) -> MockStreamEvent {
    .line(Data(json.utf8))
  }
}

extension MockTransport {
  /// A transport whose streaming side replays the given events in order and then
  /// finishes (unless an event terminates it early with `.failure`).
  public static func scriptedStream(_ events: [MockStreamEvent]) -> MockTransport {
    .streaming { _, _ in makeStream(events) }
  }

  /// A transport that serves a fresh scripted stream per connection attempt,
  /// taking scripts from `scripts` in order; attempts beyond the last script
  /// throw `TailscaleTransportError.unimplemented`. Useful for reconnect tests.
  public static func scriptedStreams(_ scripts: [[MockStreamEvent]]) -> MockTransport {
    let remaining = ScriptQueue(scripts)
    return .streaming { _, _ in
      guard let events = await remaining.next() else {
        throw TailscaleTransportError.unimplemented
      }
      return makeStream(events)
    }
  }

  private static func makeStream(_ events: [MockStreamEvent]) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        for event in events {
          if Task.isCancelled { break }
          switch event {
          case .line(let data):
            continuation.yield(data)
          case .delay(let duration):
            try? await Task.sleep(for: duration)
          case .failure(let error):
            continuation.finish(throwing: error)
            return
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private actor ScriptQueue {
  private var scripts: [[MockStreamEvent]]

  init(_ scripts: [[MockStreamEvent]]) {
    self.scripts = scripts
  }

  func next() -> [MockStreamEvent]? {
    guard !scripts.isEmpty else { return nil }
    return scripts.removeFirst()
  }
}
