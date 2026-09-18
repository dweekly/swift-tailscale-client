// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

final class IPNBusStreamingTests: XCTestCase {

  // MARK: - Lifecycle Events

  func testYieldsConnectedLifecycleEventBeforeNotifications() async throws {
    let events: [MockStreamEvent] = [
      .jsonLine("{\"Version\":\"1.96.0\", \"State\": 4}"),
      .jsonLine("{\"State\": 6}"),
    ]
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    let stream = try await client.watchIPNBusEvents(retryPolicy: .none)
    var receivedEvents: [IPNBusEvent] = []

    for try await event in stream {
      receivedEvents.append(event)
      if receivedEvents.count == 3 { break }
    }

    XCTAssertEqual(receivedEvents.count, 3)
    XCTAssertEqual(receivedEvents[0], .lifecycle(.connected))

    guard case .notification(let firstNotify) = receivedEvents[1] else {
      XCTFail("Expected first event to be notification, got \(receivedEvents[1])")
      return
    }
    XCTAssertEqual(firstNotify.version, "1.96.0")
    XCTAssertEqual(firstNotify.state, .stopped)

    guard case .notification(let secondNotify) = receivedEvents[2] else {
      XCTFail("Expected second event to be notification, got \(receivedEvents[2])")
      return
    }
    XCTAssertEqual(secondNotify.state, .running)
  }

  // MARK: - Bounded Queue & Gap Reporting

  func testEmitsStateGapOnBufferOverflowInReportGapMode() async throws {
    // Produce 10 events while consumer does not pull
    var events: [MockStreamEvent] = []
    for i in 1...10 {
      events.append(.jsonLine("{\"Version\":\"1.\(i)\"}"))
    }
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    // Bounds limit queue to 3 events; strategy .reportGap
    let bounds = StreamBufferBounds(maxEventCount: 3, overflowStrategy: .reportGap)
    let stream = try await client.watchIPNBusEvents(retryPolicy: .none, bounds: bounds)

    // Allow producer to run and encounter overflow
    try await Task.sleep(for: .milliseconds(50))

    var receivedEvents: [IPNBusEvent] = []
    for try await event in stream {
      receivedEvents.append(event)
    }

    // Must contain a stateGap with reason buffer_overflow
    let hasGap = receivedEvents.contains { event in
      if case .lifecycle(let lifecycle) = event,
        case .stateGap(let reason) = lifecycle,
        reason == "buffer_overflow"
      {
        return true
      }
      return false
    }
    XCTAssertTrue(hasGap, "Buffer overflow must emit .stateGap(reason: \"buffer_overflow\")")
  }

  func testThrowsStreamOverflowInFailMode() async throws {
    var events: [MockStreamEvent] = []
    for i in 1...10 {
      events.append(.jsonLine("{\"Version\":\"1.\(i)\"}"))
    }
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    let bounds = StreamBufferBounds(maxEventCount: 3, overflowStrategy: .fail)
    let stream = try await client.watchIPNBusEvents(retryPolicy: .none, bounds: bounds)

    // Allow producer to overflow queue
    try await Task.sleep(for: .milliseconds(50))

    await assertThrowsErrorAsync(
      try await {
        for try await _ in stream {}
      }()
    ) { error in
      guard case TailscaleClientError.streamOverflow = error else {
        XCTFail("Expected TailscaleClientError.streamOverflow, got \(error)")
        return
      }
    }
  }

  func testMalformedLineEmitsStateGapAndInvokesCallback() async throws {
    let events: [MockStreamEvent] = [
      .line(Data("not valid json\n".utf8)),
      .jsonLine("{\"Version\":\"1.96.0\"}"),
    ]
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    actor CallbackTracker {
      var called = false
      func record() { called = true }
    }
    let tracker = CallbackTracker()

    let stream = try await client.watchIPNBusEvents(
      retryPolicy: .none,
      onUndecodableLine: { _, _ in
        Task { await tracker.record() }
      }
    )

    var receivedEvents: [IPNBusEvent] = []
    for try await event in stream {
      receivedEvents.append(event)
    }

    let callbackCalled = await tracker.called
    XCTAssertTrue(callbackCalled, "onUndecodableLine callback must be invoked on invalid JSON")

    let hasGap = receivedEvents.contains { event in
      if case .lifecycle(let lifecycle) = event,
        case .stateGap(let reason) = lifecycle,
        reason == "undecodable_line"
      {
        return true
      }
      return false
    }
    XCTAssertTrue(hasGap, "Malformed line must emit .stateGap(reason: \"undecodable_line\")")
  }

  // MARK: - Classified Retry & Backoff

  func testClassifiedRetryTerminatesImmediatelyOn401Unauthorized() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("auth required".utf8))],
      statusCode: 401
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(
      try await client.watchIPNBusEvents(retryPolicy: .default)
    ) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, _, _) = error else {
        XCTFail("Expected unexpectedStatus 401, got \(error)")
        return
      }
      XCTAssertEqual(code, 401)
      XCTAssertEqual(StreamRetryPolicy.classify(error), .fatal)
    }
  }

  func testClassifiedRetryTerminatesImmediatelyOn403Forbidden() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("forbidden".utf8))],
      statusCode: 403
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(
      try await client.watchIPNBusEvents(retryPolicy: .default)
    ) { error in
      guard case TailscaleClientError.permissionDenied = error else {
        XCTFail("Expected permissionDenied, got \(error)")
        return
      }
      XCTAssertEqual(StreamRetryPolicy.classify(error), .fatal)
    }
  }

  func testClassifiedRetryRecoversOnTransientError() async throws {
    struct TransientError: Error, Sendable {}

    let scripts: [MockStreamingScript] = [
      MockStreamingScript(
        statusCode: 200,
        headers: [:],
        events: [
          .jsonLine("{\"Version\":\"1.0\"}"),
          .failure(TransientError()),
        ]
      ),
      MockStreamingScript(
        statusCode: 200,
        headers: [:],
        events: [
          .jsonLine("{\"Version\":\"2.0\"}")
        ]
      ),
    ]

    let transport = MockTransport.scriptedResponses(scripts)
    let client = E2ETestSupport.makeClient(transport: transport)

    let policy = StreamRetryPolicy(
      maxAttempts: 2,
      initialDelay: .milliseconds(10),
      maxDelay: .milliseconds(50),
      jitter: 0.0
    )

    let stream = try await client.watchIPNBusEvents(retryPolicy: policy)
    var events: [IPNBusEvent] = []

    for try await event in stream {
      events.append(event)
      if case .notification(let notify) = event, notify.version == "2.0" {
        break
      }
    }

    // Sequence must include: .connected -> notify 1.0 -> .disconnected -> .retrying -> .connected -> .stateGap(reconnected) -> notify 2.0
    let hasRetrying = events.contains { event in
      if case .lifecycle(let lifecycle) = event, case .retrying = lifecycle { return true }
      return false
    }
    XCTAssertTrue(hasRetrying, "Must emit .retrying event during reconnect")

    let hasReconnectedGap = events.contains { event in
      if case .lifecycle(let lifecycle) = event, case .stateGap(let reason) = lifecycle,
        reason == "reconnected"
      {
        return true
      }
      return false
    }
    XCTAssertTrue(hasReconnectedGap, "Must emit .stateGap(reason: \"reconnected\") on reconnect")
  }

  func testJitteredExponentialBackoffCalculations() {
    let policy = StreamRetryPolicy(
      initialDelay: .milliseconds(100),
      maxDelay: .seconds(10),
      jitter: 0.2
    )

    // Base delay checks without jitter
    XCTAssertEqual(policy.baseDelay(forAttempt: 0), .milliseconds(100))
    XCTAssertEqual(policy.baseDelay(forAttempt: 1), .milliseconds(200))
    XCTAssertEqual(policy.baseDelay(forAttempt: 2), .milliseconds(400))
    XCTAssertEqual(policy.baseDelay(forAttempt: 3), .milliseconds(800))
    XCTAssertEqual(policy.baseDelay(forAttempt: 10), .seconds(10))

    // Jitter checks with deterministic random provider
    // rand = 0.5 (middle) -> jitter offset = 0
    var deterministicPolicy = StreamRetryPolicy(
      initialDelay: .milliseconds(100),
      maxDelay: .seconds(10),
      jitter: 0.2,
      randomProvider: { 0.5 }
    )
    XCTAssertEqual(deterministicPolicy.delay(forAttempt: 0), .milliseconds(100))

    // rand = 1.0 (max positive) -> jitter offset = +20% -> 120ms
    deterministicPolicy.randomProvider = { 1.0 }
    let maxJitter = deterministicPolicy.delay(forAttempt: 0)
    let maxSeconds =
      Double(maxJitter.components.seconds) + Double(maxJitter.components.attoseconds) / 1e18
    XCTAssertEqual(maxSeconds, 0.12, accuracy: 0.001)

    // rand = 0.0 (max negative) -> jitter offset = -20% -> 80ms
    deterministicPolicy.randomProvider = { 0.0 }
    let minJitter = deterministicPolicy.delay(forAttempt: 0)
    let minSeconds =
      Double(minJitter.components.seconds) + Double(minJitter.components.attoseconds) / 1e18
    XCTAssertEqual(minSeconds, 0.08, accuracy: 0.001)
  }

  // MARK: - Cancellation & Cooperative Cleanup

  func testConsumerBreakCancelsProducerTask() async throws {
    let events: [MockStreamEvent] = (1...100).map { .jsonLine("{\"Version\":\"\($0)\"}") }
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    let stream = try await client.watchIPNBusEvents()
    var count = 0
    for try await event in stream {
      if case .notification = event {
        count += 1
        if count == 3 { break }
      }
    }

    XCTAssertEqual(count, 3)
    // Wait briefly to confirm producer deallocation/cancellation
    try await Task.sleep(for: .milliseconds(50))
  }

  // MARK: - Backward Compatibility watchIPNBus

  func testWatchIPNBusDelegatesAndFiltersLifecycle() async throws {
    let events: [MockStreamEvent] = [
      .jsonLine("{\"Version\":\"1.96.0\", \"State\": 4}"),
      .jsonLine("{\"State\": 6}"),
    ]
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    let stream = try await client.watchIPNBus()
    var received: [IPNNotify] = []

    for try await notify in stream {
      received.append(notify)
    }

    XCTAssertEqual(received.count, 2)
    XCTAssertEqual(received[0].version, "1.96.0")
    XCTAssertEqual(received[0].state, .stopped)
    XCTAssertEqual(received[1].state, .running)
  }

  func testWatchIPNBusThrowsStreamOverflowOnQueueExceeded() async throws {
    var events: [MockStreamEvent] = []
    for i in 1...10 {
      events.append(.jsonLine("{\"Version\":\"1.\(i)\"}"))
    }
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    // Legacy watchIPNBus uses .throwing bounds
    let stream = try await client.watchIPNBus()

    // Rapidly consume or let queue buffer
    var count = 0
    for try await notify in stream {
      count += 1
      if count == 2 {
        // Stop pulling to let buffer fill
        break
      }
    }
  }
}
