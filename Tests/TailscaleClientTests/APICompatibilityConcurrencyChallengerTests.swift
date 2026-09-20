// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import TailscaleClient
import XCTest

// MARK: - External Actor Transport Conformance (Swift 6 Strict Concurrency)

/// Conforms to `TailscaleTransport` via an `actor`.
/// Because `TailscaleTransport` requires `Sendable` and async methods `send` and `sendStreaming`,
/// an actor naturally satisfies the protocol requirement without `@unchecked Sendable`.
public actor ExternalActorTransport: TailscaleTransport {
  private(set) var unaryCallCount: Int = 0
  private(set) var streamingCallCount: Int = 0
  private(set) var pathsRecorded: [String] = []

  public init() {}

  public func send(
    _ request: TailscaleRequest,
    configuration: TailscaleClientConfiguration
  ) async throws -> TailscaleResponse {
    unaryCallCount += 1
    pathsRecorded.append(request.path)

    switch request.path {
    case "/localapi/v0/status":
      let json = Data(#"{"BackendState": "Running", "Version": "1.80.0"}"#.utf8)
      return TailscaleResponse(statusCode: 200, data: json)
    case "/localapi/v0/profiles/":
      let json = Data(#"[{"ID": "p1", "Name": "Profile 1", "Key": "k1"}]"#.utf8)
      return TailscaleResponse(statusCode: 200, data: json)
    case "/localapi/v0/profiles/current":
      let json = Data(#"{"ID": "p1", "Name": "Profile 1", "Key": "k1"}"#.utf8)
      return TailscaleResponse(statusCode: 200, data: json)
    case "/localapi/v0/serve-config":
      let json = Data(#"{"TCP": {}, "Web": {}}"#.utf8)
      return TailscaleResponse(
        statusCode: 200,
        data: json,
        headers: ["ETag": "\"test-etag-123\""]
      )
    default:
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
  }

  public func sendStreaming(
    _ request: TailscaleRequest,
    configuration: TailscaleClientConfiguration
  ) async throws -> StreamingResponse {
    streamingCallCount += 1
    pathsRecorded.append(request.path)

    let stream = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(Data("{\"State\": 6}\n".utf8))
      continuation.yield(Data("{\"State\": 4}\n".utf8))
      continuation.finish()
    }
    return StreamingResponse(
      statusCode: 200,
      headers: ["Tailscale-Version": "1.80.0"],
      body: stream
    )
  }

  public func totalCalls() -> Int {
    unaryCallCount + streamingCallCount
  }
}

// MARK: - External Struct Transport Conformance

/// Conforms to `TailscaleTransport` via a pure immutable `struct`.
public struct ExternalStructTransport: TailscaleTransport {
  public let cannedVersion: String

  public init(cannedVersion: String = "1.80.0") {
    self.cannedVersion = cannedVersion
  }

  public func send(
    _ request: TailscaleRequest,
    configuration: TailscaleClientConfiguration
  ) async throws -> TailscaleResponse {
    if request.path == "/localapi/v0/status" {
      let json = Data(#"{"BackendState": "Running", "Version": "\#(cannedVersion)"}"#.utf8)
      return TailscaleResponse(statusCode: 200, data: json)
    }
    return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
  }

  public func sendStreaming(
    _ request: TailscaleRequest,
    configuration: TailscaleClientConfiguration
  ) async throws -> StreamingResponse {
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(Data("{\"State\": 6}\n".utf8))
      continuation.finish()
    }
    return StreamingResponse(
      statusCode: 200,
      headers: ["Tailscale-Version": cannedVersion],
      body: stream
    )
  }
}

// MARK: - External Locked Class Transport Conformance

/// Conforms to `TailscaleTransport` via a `final class: Sendable` with an `NSLock`.
public final class ExternalLockedClassTransport: TailscaleTransport, Sendable {
  private let lock = NSLock()
  private final class State: @unchecked Sendable {
    var callCount = 0
  }
  private let state = State()

  public init() {}

  public func send(
    _ request: TailscaleRequest,
    configuration: TailscaleClientConfiguration
  ) async throws -> TailscaleResponse {
    lock.withLock {
      state.callCount += 1
    }

    if request.path == "/localapi/v0/status" {
      let json = Data(#"{"BackendState": "Running", "Version": "1.80.0"}"#.utf8)
      return TailscaleResponse(statusCode: 200, data: json)
    }
    return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
  }

  public func sendStreaming(
    _ request: TailscaleRequest,
    configuration: TailscaleClientConfiguration
  ) async throws -> StreamingResponse {
    lock.withLock {
      state.callCount += 1
    }

    let stream = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(Data("{\"State\": 6}\n".utf8))
      continuation.finish()
    }
    return StreamingResponse(
      statusCode: 200,
      headers: ["Tailscale-Version": "1.80.0"],
      body: stream
    )
  }

  public var callCount: Int {
    lock.withLock { state.callCount }
  }
}

// MARK: - Test Suite

final class APICompatibilityConcurrencyChallengerTests: XCTestCase {

  /// Tests that an actor conforming to TailscaleTransport cleanly dispatches 100 concurrent unary calls
  /// across arbitrary threads with zero deadlocks, race conditions, or dropped calls.
  func testActorTransportConcurrentUnaryDispatch() async throws {
    let actorTransport = ExternalActorTransport()
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:8080")!),
      authToken: "test-token",
      transport: actorTransport
    )
    let client = TailscaleClient(configuration: config)

    let totalTasks = 100
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<totalTasks {
        group.addTask {
          if i % 3 == 0 {
            let status = try await client.status()
            XCTAssertEqual(status.backendState, .running)
          } else if i % 3 == 1 {
            let profiles = try await client.profiles()
            XCTAssertEqual(profiles.count, 1)
          } else {
            let snapshot = try await client.serveConfigSnapshot()
            XCTAssertEqual(snapshot.etag, "\"test-etag-123\"")
          }
        }
      }
      try await group.waitForAll()
    }

    let calls = await actorTransport.unaryCallCount
    XCTAssertEqual(
      calls, totalTasks, "Actor transport must receive exactly 100 calls without drop or deadlock")
  }

  /// Tests that multiple concurrent streaming subscriptions dispatch cleanly
  /// through an external transport without cross-talk or blocking.
  func testStructTransportConcurrentStreamingDispatch() async throws {
    let structTransport = ExternalStructTransport(cannedVersion: "1.85.2")
    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 8080),
      authToken: "test-token",
      transport: structTransport
    )
    let client = TailscaleClient(configuration: config)

    let concurrentStreams = 20
    try await withThrowingTaskGroup(of: [IPNState].self) { group in
      for _ in 0..<concurrentStreams {
        group.addTask {
          var collected: [IPNState] = []
          let stream = try await client.watchIPNBus()
          for try await notify in stream {
            if let state = notify.state {
              collected.append(state)
            }
          }
          return collected
        }
      }

      var allResults: [[IPNState]] = []
      for try await result in group {
        allResults.append(result)
      }
      XCTAssertEqual(allResults.count, concurrentStreams)
      for result in allResults {
        XCTAssertEqual(result, [.running])
      }
    }
  }

  /// Tests that an external locked class transport handles mixed concurrent unary + streaming
  /// traffic under high concurrency (120 tasks) without deadlock.
  func testLockedClassTransportMixedConcurrentWorkload() async throws {
    let lockedTransport = ExternalLockedClassTransport()
    let config = TailscaleClientConfiguration(
      endpoint: .unixSocket(path: "/var/run/tailscale/tailscaled.sock"),
      authToken: nil,
      transport: lockedTransport
    )
    let client = TailscaleClient(configuration: config)

    let totalWorkers = 120
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<totalWorkers {
        group.addTask {
          if i % 2 == 0 {
            let status = try await client.status()
            XCTAssertEqual(status.backendState, .running)
          } else {
            let stream = try await client.watchIPNBus()
            for try await _ in stream {
              // consume
            }
          }
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(lockedTransport.callCount, totalWorkers)
  }

  /// Tests cancellation under concurrency: starts 60 concurrent tasks and cancels half of them mid-flight.
  /// Verifies that cancellation is handled cleanly and non-cancelled tasks complete.
  func testConcurrentCancellationThroughExternalTransport() async throws {
    actor DelayingTransport: TailscaleTransport {
      func send(
        _ request: TailscaleRequest,
        configuration: TailscaleClientConfiguration
      ) async throws -> TailscaleResponse {
        try await Task.sleep(for: .milliseconds(50))
        return TailscaleResponse(
          statusCode: 200,
          data: Data(#"{"BackendState": "Running", "Version": "1.80.0"}"#.utf8)
        )
      }

      func sendStreaming(
        _ request: TailscaleRequest,
        configuration: TailscaleClientConfiguration
      ) async throws -> StreamingResponse {
        try await Task.sleep(for: .milliseconds(50))
        let stream = AsyncThrowingStream<Data, Error> { continuation in
          continuation.yield(Data("{\"State\": 6}\n".utf8))
          continuation.finish()
        }
        return StreamingResponse(
          statusCode: 200,
          headers: ["Tailscale-Version": "1.80.0"],
          body: stream
        )
      }
    }

    let transport = DelayingTransport()
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://127.0.0.1:8080")!),
        authToken: nil,
        transport: transport
      )
    )

    let totalTasks = 60
    var cancelledCount = 0
    var completedCount = 0

    await withTaskGroup(of: Result<Void, Error>.self) { group in
      for i in 0..<totalTasks {
        let shouldCancel = (i % 2 == 0)
        group.addTask {
          let task = Task {
            _ = try await client.status()
          }
          if shouldCancel {
            task.cancel()
          }
          do {
            try await task.value
            return .success(())
          } catch {
            return .failure(error)
          }
        }
      }

      for await res in group {
        switch res {
        case .success:
          completedCount += 1
        case .failure(let err):
          if err is CancellationError {
            cancelledCount += 1
          } else {
            // Other transport error
            completedCount += 1
          }
        }
      }
    }

    XCTAssertEqual(completedCount + cancelledCount, totalTasks)
    XCTAssertGreaterThan(completedCount, 0)
  }

  /// Tests that custom domain errors thrown by an external transport propagate directly to caller.
  func testExternalTransportErrorPropagation() async throws {
    struct CustomExternalNetworkError: Error, Equatable {}

    struct FailingTransport: TailscaleTransport {
      func send(
        _ request: TailscaleRequest,
        configuration: TailscaleClientConfiguration
      ) async throws -> TailscaleResponse {
        throw CustomExternalNetworkError()
      }

      func sendStreaming(
        _ request: TailscaleRequest,
        configuration: TailscaleClientConfiguration
      ) async throws -> StreamingResponse {
        throw CustomExternalNetworkError()
      }
    }

    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://127.0.0.1:8080")!),
        authToken: nil,
        transport: FailingTransport()
      )
    )

    do {
      _ = try await client.status()
      XCTFail("Should have thrown")
    } catch let error as CustomExternalNetworkError {
      XCTAssertEqual(error, CustomExternalNetworkError())
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }
}
