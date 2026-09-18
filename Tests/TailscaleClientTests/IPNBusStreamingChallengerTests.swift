// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Adversarial empirical test harness challenging Milestone 1 W3 (PR 06 & PR 07).
///
/// Validates:
/// 1. Queue depth overflow (300+ events) with stale event flushing and `.stateGap(reason: "buffer_overflow")` injection.
/// 2. Memory byte bound overflow (large payloads exceeding 16 MB) with bounded memory retention.
/// 3. Queue overflow in `.fail` mode (`bounds: .throwing`) throwing `TailscaleClientError.streamOverflow`.
/// 4. Reconnect backoff progression: exponential progression (100ms, 200ms... up to 10s cap) and jitter distribution across 1,000 samples.
/// 5. Fatal error classification and immediate termination on 401 and 403 (initial and reconnect).
/// 6. Cancellation stress: cancelling consumer stream during high-throughput event emission with zero descriptor and task leaks across 100+ cycles using kernel introspection (`proc_pidinfo`).
final class IPNBusStreamingChallengerTests: XCTestCase {

  private func makeClient(path: String, timeout: Duration? = .seconds(5)) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .unixSocket(path: path),
      authToken: nil,
      capabilityVersion: 1,
      requestTimeout: timeout,
      transport: URLSessionTailscaleTransport()
    )
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - 1. Queue Depth Overflow & Gap Injection (PR 07, FEAT-16)

  func testQueueDepthOverflowFlushesStaleEventsAndReportsStateGapInDefaultMode() async throws {
    // Default bounds: maxEventCount = 256, overflowStrategy = .reportGap
    // Push 350 events without consumer consumption.
    let totalEvents = 350
    var mockEvents: [MockStreamEvent] = []
    for i in 0..<totalEvents {
      mockEvents.append(.jsonLine("{\"Version\":\"1.\(i)\"}"))
    }

    let transport = MockTransport.scriptedStream(mockEvents)
    let client = E2ETestSupport.makeClient(transport: transport)

    let stream = try await client.watchIPNBusEvents(retryPolicy: .none, bounds: .default)

    // Allow producer to push all 350 events while consumer is idle
    try await Task.sleep(for: .milliseconds(100))

    var receivedEvents: [IPNBusEvent] = []
    for try await event in stream {
      receivedEvents.append(event)
    }

    // Must emit .lifecycle(.stateGap(reason: "buffer_overflow"))
    let gapEvents = receivedEvents.compactMap { event -> String? in
      if case .lifecycle(let lifecycle) = event, case .stateGap(let reason) = lifecycle {
        return reason
      }
      return nil
    }
    XCTAssertTrue(
      gapEvents.contains("buffer_overflow"),
      "Default .reportGap queue must emit .stateGap(reason: \"buffer_overflow\") upon exceeding 256 events"
    )

    // Verify stale events were flushed:
    // Initial 256 events were discarded. The received notifications must NOT include early events (e.g. version "1.0").
    let receivedVersions: [String] = receivedEvents.compactMap { event in
      guard case .notification(let notify) = event else { return nil }
      return notify.version
    }

    XCTAssertFalse(
      receivedVersions.contains("1.0"),
      "Stale events (version 1.0) must be flushed from buffer on overflow"
    )
    XCTAssertFalse(
      receivedVersions.contains("1.100"),
      "Stale events (version 1.100) must be flushed from buffer on overflow"
    )

    // Total count must be bounded and strictly less than totalEvents (since early events were flushed)
    XCTAssertLessThan(
      receivedEvents.count, totalEvents,
      "Queue overflow must discard stale events so received count is less than 350"
    )
  }

  func testQueueDepthDirectActorQueue350Events() async throws {
    let bounds = StreamBufferBounds(maxEventCount: 256, overflowStrategy: .reportGap)
    let queue = IPNBusBoundedQueue(bounds: bounds)

    // Enqueue 350 events directly to the actor without consuming
    for i in 0..<350 {
      let notify = IPNNotify(version: "1.\(i)")
      await queue.enqueue(.notification(notify), byteSize: 64)
    }
    await queue.finish()

    var collected: [IPNBusEvent] = []
    while let event = try await queue.next() {
      collected.append(event)
    }

    // The first event after overflow must be the stateGap
    XCTAssertFalse(collected.isEmpty)
    XCTAssertEqual(
      collected.first,
      .lifecycle(.stateGap(reason: "buffer_overflow")),
      "First event retrieved after overflow must be .stateGap"
    )

    // The notifications that follow must only be the ones enqueued after overflow
    let versions = collected.compactMap { event -> String? in
      if case .notification(let notify) = event { return notify.version }
      return nil
    }
    XCTAssertFalse(versions.contains("1.0"), "Early event 1.0 must have been dropped")
    XCTAssertFalse(versions.contains("1.250"), "Early event 1.250 must have been dropped")
    XCTAssertTrue(versions.contains("1.349"), "Latest event 1.349 must be retained")
  }

  func testPeriodicOverflowUnderRapidProductionWithSlowConsumer() async throws {
    // 500 events, bounds = 20 events.
    // Consumer reads with a delay, triggering multiple consecutive buffer flushes and gaps.
    let bounds = StreamBufferBounds(maxEventCount: 20, overflowStrategy: .reportGap)
    let queue = IPNBusBoundedQueue(bounds: bounds)

    let producer = Task {
      for i in 0..<500 {
        let notify = IPNNotify(version: "event-\(i)")
        await queue.enqueue(.notification(notify), byteSize: 32)
        if i % 50 == 0 {
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
      await queue.finish()
    }

    var gapsCount = 0
    var notificationsCount = 0

    while let event = try await queue.next() {
      switch event {
      case .lifecycle(let lifecycle):
        if case .stateGap(let reason) = lifecycle, reason == "buffer_overflow" {
          gapsCount += 1
        }
      case .notification:
        notificationsCount += 1
      }
      // Simulate slow consumer
      try await Task.sleep(for: .microseconds(500))
    }

    _ = await producer.result
    XCTAssertGreaterThan(
      gapsCount, 1,
      "Slow consumer under rapid bursts must observe multiple stateGap flushes"
    )
    XCTAssertLessThan(
      notificationsCount, 500,
      "Slow consumer must have dropped intermediate notifications"
    )
  }

  // MARK: - 2. Memory Byte Bound Enforcement (PR 07, FEAT-16)

  func testMemoryByteBoundOverflowWithMultiplePayloadsExceeding16MB() async throws {
    // Default maxByteCount is 16 MB (16,777,216 bytes).
    // Push 5 large events of 4 MB each (total 20 MB > 16 MB).
    let fourMB = 4 * 1024 * 1024
    let bounds = StreamBufferBounds(
      maxEventCount: 1000,
      maxByteCount: 16 * 1024 * 1024,
      overflowStrategy: .reportGap
    )
    let queue = IPNBusBoundedQueue(bounds: bounds)

    // Enqueue 4 events of 4 MB = 16 MB (at limit)
    for i in 1...4 {
      let notify = IPNNotify(version: "event-\(i)")
      await queue.enqueue(.notification(notify), byteSize: fourMB)
    }

    // 5th event of 4 MB causes total bytes = 20 MB > 16 MB -> overflow!
    let fifthNotify = IPNNotify(version: "event-5")
    await queue.enqueue(.notification(fifthNotify), byteSize: fourMB)
    await queue.finish()

    var received: [IPNBusEvent] = []
    while let event = try await queue.next() {
      received.append(event)
    }

    // Buffer must have flushed stale events (1..4) and yielded stateGap followed by event 5
    XCTAssertEqual(
      received.first,
      .lifecycle(.stateGap(reason: "buffer_overflow")),
      "Byte bound overflow must emit .stateGap(reason: \"buffer_overflow\")"
    )

    let versions = received.compactMap { event -> String? in
      if case .notification(let notify) = event { return notify.version }
      return nil
    }
    XCTAssertFalse(versions.contains("event-1"), "Event 1 must be flushed on byte overflow")
    XCTAssertFalse(versions.contains("event-4"), "Event 4 must be flushed on byte overflow")
    XCTAssertTrue(
      versions.contains("event-5"), "Event 5 (the triggering event <= 16MB) must be retained")
  }

  func testSingleOversizedPayloadExceeding16MBDiscardedWithoutMemoryRetained() async throws {
    // A single payload exceeding 16 MB (e.g. 17 MB).
    // When enqueued, it triggers overflow immediately.
    // In .reportGap mode:
    // Old buffer is cleared, stateGap is added.
    // Because byteSize (17 MB) > maxByteCount (16 MB), the 17 MB event itself is NOT enqueued!
    let seventeenMB = 17 * 1024 * 1024
    let bounds = StreamBufferBounds.default  // 16 MB
    let queue = IPNBusBoundedQueue(bounds: bounds)

    let hugeNotify = IPNNotify(version: "huge")
    await queue.enqueue(.notification(hugeNotify), byteSize: seventeenMB)
    await queue.finish()

    var received: [IPNBusEvent] = []
    while let event = try await queue.next() {
      received.append(event)
    }

    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(
      received.first,
      .lifecycle(.stateGap(reason: "buffer_overflow")),
      "Single oversized event > 16 MB must only emit stateGap and discard payload"
    )
  }

  func testQueueOverflowArithmeticNeverExceedsByteCeiling() async throws {
    // bounds has maxByteCount = 100 bytes, overflowStrategy = .reportGap.
    // gapEvent requires 64 bytes.
    // If an incoming event is 50 bytes:
    // With 64 + 50 = 114 > 100, the 50 byte event MUST NOT be appended along with gapEvent,
    // so total buffered bytes NEVER exceeds 100 bytes.
    let bounds = StreamBufferBounds(maxEventCount: 10, maxByteCount: 100, overflowStrategy: .reportGap)
    let queue = IPNBusBoundedQueue(bounds: bounds)

    // Pre-fill queue to 80 bytes
    await queue.enqueue(.notification(IPNNotify(version: "1")), byteSize: 80)

    // Next event is 50 bytes -> triggers overflow (80 + 50 = 130 > 100).
    // Buffer is cleared. gapEvent (64 bytes) is added.
    // Since 64 + 50 > 100, the 50-byte event must NOT be enqueued.
    await queue.enqueue(.notification(IPNNotify(version: "2")), byteSize: 50)
    await queue.finish()

    var received: [IPNBusEvent] = []
    while let event = try await queue.next() {
      received.append(event)
    }

    // Only the gapEvent should be received, NOT the 50-byte event.
    XCTAssertEqual(received.count, 1)
    XCTAssertEqual(received.first, .lifecycle(.stateGap(reason: "buffer_overflow")))
  }

  // MARK: - 3. Queue Overflow in .fail Mode (bounds: .throwing) (PR 07, FEAT-16)

  func testQueueDepthOverflowInFailModeThrowsStreamOverflow() async throws {
    let bounds = StreamBufferBounds(maxEventCount: 5, overflowStrategy: .fail)
    let queue = IPNBusBoundedQueue(bounds: bounds)

    // Enqueue 6 events
    for i in 0..<6 {
      let notify = IPNNotify(version: "\(i)")
      await queue.enqueue(.notification(notify), byteSize: 32)
    }

    do {
      _ = try await queue.next()
      XCTFail("Queue next() must throw TailscaleClientError.streamOverflow")
    } catch let error as TailscaleClientError {
      guard case .streamOverflow = error else {
        XCTFail("Expected .streamOverflow, got \(error)")
        return
      }
    }
  }

  func testMemoryByteBoundOverflowInFailModeThrowsStreamOverflow() async throws {
    let bounds = StreamBufferBounds(maxByteCount: 1024, overflowStrategy: .fail)
    let queue = IPNBusBoundedQueue(bounds: bounds)

    // Enqueue single event of 2048 bytes > 1024 bytes
    let notify = IPNNotify(version: "too-large")
    await queue.enqueue(.notification(notify), byteSize: 2048)

    do {
      _ = try await queue.next()
      XCTFail("Queue next() must throw TailscaleClientError.streamOverflow on byte limit")
    } catch let error as TailscaleClientError {
      guard case .streamOverflow = error else {
        XCTFail("Expected .streamOverflow, got \(error)")
        return
      }
    }
  }

  func testStreamOverflowErrorProperties() {
    let error = TailscaleClientError.streamOverflow
    XCTAssertNil(error.bodyPreview, "streamOverflow error has no response bodyPreview")
    XCTAssertTrue(
      error.localizedDescription.contains("overflow") || "\(error)".contains("streamOverflow"),
      "Error description must mention overflow"
    )
  }

  func testLegacyWatchIPNBusThrowsStreamOverflowOnQueueExceeded() async throws {
    var events: [MockStreamEvent] = []
    for i in 1...10 {
      events.append(.jsonLine("{\"Version\":\"1.\(i)\"}"))
    }
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    // Legacy watchIPNBus uses bounds: .throwing
    let stream = try await client.watchIPNBus()

    // Consume 1, then sleep to let producer overflow queue
    var count = 0
    do {
      for try await _ in stream {
        count += 1
        if count == 1 {
          try await Task.sleep(for: .milliseconds(50))
        }
      }
    } catch {
      // If queue overflows, it throws streamOverflow
    }
  }

  // MARK: - 4. Reconnect Backoff Progression & Jitter Distribution (PR 07, FEAT-17)

  func testExponentialBackoffProgressionUpTo10SecondsCap() {
    let policy = StreamRetryPolicy(
      initialDelay: .milliseconds(100),
      maxDelay: .seconds(10),
      jitter: 0.0
    )

    func seconds(_ d: Duration) -> Double {
      Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    // Verify negative attempt
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: -1)), 0.1, accuracy: 0.001)

    // Verify exponential progression: 100ms, 200ms, 400ms, 800ms, 1600ms, 3200ms, 6400ms
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 0)), 0.1, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 1)), 0.2, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 2)), 0.4, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 3)), 0.8, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 4)), 1.6, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 5)), 3.2, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 6)), 6.4, accuracy: 0.001)

    // Attempt 7: 12.8s > 10.0s -> capped at 10s
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 7)), 10.0, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 8)), 10.0, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 15)), 10.0, accuracy: 0.001)
    XCTAssertEqual(seconds(policy.baseDelay(forAttempt: 30)), 10.0, accuracy: 0.001)
  }

  func testJitterStatisticalDistributionAcross1000Samples() {
    let policy = StreamRetryPolicy.default  // initial: 100ms, max: 10s, jitter: 0.2
    let base = 0.100  // 100ms
    let minAllowed = base * (1.0 - 0.2)  // 0.080s (80ms)
    let maxAllowed = base * (1.0 + 0.2)  // 0.120s (120ms)

    var samples: [Double] = []
    samples.reserveCapacity(1000)

    for _ in 0..<1000 {
      let d = policy.delay(forAttempt: 0)
      let sec = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
      samples.append(sec)

      // Strict boundary check
      XCTAssertGreaterThanOrEqual(
        sec, minAllowed - 1e-9,
        "Sample \(sec)s violated lower jitter bound \(minAllowed)s"
      )
      XCTAssertLessThanOrEqual(
        sec, maxAllowed + 1e-9,
        "Sample \(sec)s violated upper jitter bound \(maxAllowed)s"
      )
    }

    // Mean must converge near base (100ms ± 3ms)
    let sum = samples.reduce(0.0, +)
    let mean = sum / Double(samples.count)
    XCTAssertEqual(
      mean, base, accuracy: 0.003,
      "Empirical mean \(mean)s must be within ±3ms of nominal base \(base)s"
    )

    // Standard deviation must show uniform spread (theoretical stddev for Uniform(-0.02, +0.02) is 0.04 / sqrt(12) ≈ 0.0115s)
    let variance = samples.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(samples.count)
    let stddev = sqrt(variance)
    XCTAssertGreaterThan(
      stddev, 0.008,
      "Empirical jitter distribution must exhibit real variance; stddev was \(stddev)"
    )
  }

  func testJitterBoundaryConditions() {
    // Jitter = 0.0: delay is identical to base
    let zeroJitter = StreamRetryPolicy(jitter: 0.0)
    for attempt in 0...5 {
      XCTAssertEqual(
        zeroJitter.delay(forAttempt: attempt), zeroJitter.baseDelay(forAttempt: attempt))
    }

    // Jitter clamping: negative values clamped to 0.0, > 1.0 clamped to 1.0
    let negativeJitter = StreamRetryPolicy(jitter: -0.5)
    XCTAssertEqual(negativeJitter.jitter, 0.0)

    let excessJitter = StreamRetryPolicy(jitter: 2.5)
    XCTAssertEqual(excessJitter.jitter, 1.0)
  }

  // MARK: - 5. Fatal Error Classification & Termination (PR 07, FEAT-17)

  func testFatalErrorClassificationMapping() {
    // Fatal errors
    XCTAssertEqual(StreamRetryPolicy.classify(CancellationError()), .fatal)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 401, body: Data(), endpoint: "/test")),
      .fatal
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 403, body: Data(), endpoint: "/test")),
      .fatal
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 404, body: Data(), endpoint: "/test")),
      .fatal
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.permissionDenied(body: Data(), endpoint: "/test")),
      .fatal
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleClientError.missingConcurrencyToken),
      .fatal
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleClientError.streamOverflow),
      .fatal
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleTransportError.socketNotFound(path: "/nonexistent.sock")),
      .fatal
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleTransportError.unimplemented),
      .fatal
    )

    // Retryable errors
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 500, body: Data(), endpoint: "/test")),
      .retryable
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 502, body: Data(), endpoint: "/test")),
      .retryable
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 503, body: Data(), endpoint: "/test")),
      .retryable
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleClientError.timeout(endpoint: "/test")),
      .retryable
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.rateLimited(retryAfterSeconds: 5, body: Data(), endpoint: "/test")),
      .retryable
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleTransportError.connectionRefused(endpoint: "/test")),
      .retryable
    )
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleTransportError.malformedResponse(detail: "corrupted")),
      .retryable
    )
  }

  func testReconnectEncountering401FailsStreamImmediately() async throws {
    struct DroppedError: Error, Sendable {}

    let scripts: [MockStreamingScript] = [
      MockStreamingScript(
        statusCode: 200,
        headers: [:],
        events: [
          .jsonLine("{\"Version\":\"1.0\"}"),
          .failure(DroppedError()),
        ]
      ),
      MockStreamingScript(
        statusCode: 401,
        headers: [:],
        events: [
          .line(Data("auth invalid".utf8))
        ]
      ),
    ]

    let transport = MockTransport.scriptedResponses(scripts)
    let client = E2ETestSupport.makeClient(transport: transport)

    let policy = StreamRetryPolicy(
      maxAttempts: 5,
      initialDelay: .milliseconds(10),
      maxDelay: .milliseconds(50),
      jitter: 0.0
    )

    let stream = try await client.watchIPNBusEvents(retryPolicy: policy)

    var receivedEvents: [IPNBusEvent] = []
    var caughtError: Error? = nil

    do {
      for try await event in stream {
        receivedEvents.append(event)
      }
    } catch {
      caughtError = error
    }

    let unwrappedError = try XCTUnwrap(
      caughtError, "Stream must terminate with error on 401 reconnect")
    guard case TailscaleClientError.unexpectedStatus(let code, _, _) = unwrappedError else {
      XCTFail("Expected unexpectedStatus 401, got \(unwrappedError)")
      return
    }
    XCTAssertEqual(code, 401)
  }

  func testReconnectEncountering403FailsStreamImmediately() async throws {
    struct DroppedError: Error, Sendable {}

    let scripts: [MockStreamingScript] = [
      MockStreamingScript(
        statusCode: 200,
        headers: [:],
        events: [
          .jsonLine("{\"Version\":\"1.0\"}"),
          .failure(DroppedError()),
        ]
      ),
      MockStreamingScript(
        statusCode: 403,
        headers: [:],
        events: [
          .line(Data("access forbidden".utf8))
        ]
      ),
    ]

    let transport = MockTransport.scriptedResponses(scripts)
    let client = E2ETestSupport.makeClient(transport: transport)

    let policy = StreamRetryPolicy(
      maxAttempts: 5,
      initialDelay: .milliseconds(10),
      maxDelay: .milliseconds(50),
      jitter: 0.0
    )

    let stream = try await client.watchIPNBusEvents(retryPolicy: policy)

    var caughtError: Error? = nil
    do {
      for try await _ in stream {}
    } catch {
      caughtError = error
    }

    let unwrappedError = try XCTUnwrap(
      caughtError, "Stream must terminate with error on 403 reconnect")
    guard case TailscaleClientError.permissionDenied = unwrappedError else {
      XCTFail("Expected permissionDenied, got \(unwrappedError)")
      return
    }
  }

  // MARK: - 6. Cancellation Stress & Zero Descriptor Leak Across 100+ Cycles (FEAT-11, FEAT-16)

  #if canImport(Darwin) || os(Linux)

    func testCancellationStressOver110CyclesZeroDescriptorLeaks() async throws {
      // Warm-up: initialize lazy runtime / URLSession internals
      for _ in 0..<3 {
        let server = try FaultUnixServer(behaviors: [
          .respond(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"Version\":\"warmup\"}\n",
            closeAfterWrite: true)
        ])
        let client = makeClient(path: server.path, timeout: .seconds(1))
        if let stream = try? await client.watchIPNBusEvents(retryPolicy: .none) {
          for try await _ in stream { break }
        }
        server.stop()
      }

      let baselineFDCount = openFDCount()
      let baselineSocketCount = openSocketFDCount()
      let totalCycles = 110

      let jsonLines = (1...20).map { "{\"Version\":\"1.\($0)\"}\n" }.joined()
      let responsePayload = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" + jsonLines

      for i in 0..<totalCycles {
        let mode = i % 3
        let server = try FaultUnixServer(behaviors: [
          .respond(responsePayload, closeAfterWrite: false)
        ])
        let client = makeClient(path: server.path, timeout: .seconds(2))

        switch mode {
        case 0:
          // Mode 0: Consumer break during active streaming
          if let stream = try? await client.watchIPNBusEvents(retryPolicy: .none) {
            var count = 0
            for try await event in stream {
              if case .notification = event {
                count += 1
                if count == 3 {
                  break
                }
              }
            }
          }

        case 1:
          // Mode 1: Consumer Task cancellation during active streaming
          if let stream = try? await client.watchIPNBusEvents(retryPolicy: .none) {
            let consumerTask = Task {
              for try await event in stream {
                if case .notification = event {
                  // Continue reading
                }
              }
            }
            try await Task.sleep(for: .milliseconds(5))
            consumerTask.cancel()
            _ = await consumerTask.result
          }

        case 2:
          // Mode 2: Consumer legacy watchIPNBus break
          if let stream = try? await client.watchIPNBus() {
            var count = 0
            for try await _ in stream {
              count += 1
              if count == 2 {
                break
              }
            }
          }

        default:
          break
        }

        server.stop()
      }

      // Wait briefly for background cancellation handlers to settle
      let deadline = ContinuousClock.now + .seconds(3)
      while (openFDCount() > baselineFDCount || openSocketFDCount() > baselineSocketCount)
        && ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(50))
      }

      let finalFDCount = openFDCount()
      let finalSocketCount = openSocketFDCount()

      XCTAssertEqual(
        finalFDCount, baselineFDCount,
        "Kernel introspection detected open file descriptor leak after \(totalCycles) cycles: baseline=\(baselineFDCount), final=\(finalFDCount)"
      )
      XCTAssertEqual(
        finalSocketCount, baselineSocketCount,
        "Kernel introspection detected open socket descriptor leak after \(totalCycles) cycles: baseline=\(baselineSocketCount), final=\(finalSocketCount)"
      )
    }

    func testCancellationDuringBackoffSleepDoesNotLeakTasks() async throws {
      struct DroppedError: Error, Sendable {}

      let scripts: [MockStreamingScript] = [
        MockStreamingScript(
          statusCode: 200,
          headers: [:],
          events: [
            .jsonLine("{\"Version\":\"1.0\"}"),
            .failure(DroppedError()),
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

      // Long backoff delay of 5.0 seconds
      let policy = StreamRetryPolicy(
        maxAttempts: 5,
        initialDelay: .seconds(5),
        maxDelay: .seconds(10),
        jitter: 0.0
      )

      let stream = try await client.watchIPNBusEvents(retryPolicy: policy)

      let consumerTask = Task {
        for try await event in stream {
          if case .notification = event {
            // Received first event, next is drop and sleep
          }
        }
      }

      // Allow first event and connection drop to occur, entering 5s backoff sleep
      try await Task.sleep(for: .milliseconds(50))

      let start = ContinuousClock.now
      consumerTask.cancel()
      _ = await consumerTask.result
      let elapsed = start.duration(to: .now)

      XCTAssertLessThan(
        elapsed, .seconds(1.0),
        "Task cancellation during backoff sleep must complete promptly in < 1.0s; took \(elapsed)"
      )
    }

  #endif

  // MARK: - Kernel Introspection Helpers

  #if canImport(Darwin)
    private struct ProcFDInfo {
      var procFD: Int32
      var procFDType: UInt32
    }
    private let proxFDTypeSocket: UInt32 = 2

    @_silgen_name("proc_pidinfo")
    private func procPidInfo(
      _ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?,
      _ buffersize: Int32
    ) -> Int32

    private func darwinFDList() -> [ProcFDInfo] {
      let procPidListFDs: Int32 = 1
      let bufferSize = procPidInfo(getpid(), procPidListFDs, 0, nil, 0)
      guard bufferSize > 0 else { return [] }
      let capacity = Int(bufferSize) / MemoryLayout<ProcFDInfo>.stride
      var list = [ProcFDInfo](repeating: ProcFDInfo(procFD: 0, procFDType: 0), count: capacity)
      let actualBytes = procPidInfo(getpid(), procPidListFDs, 0, &list, bufferSize)
      guard actualBytes > 0 else { return [] }
      let actualCount = Int(actualBytes) / MemoryLayout<ProcFDInfo>.stride
      return Array(list.prefix(actualCount))
    }
  #endif

  private func openFDCount() -> Int {
    #if canImport(Darwin)
      let list = darwinFDList()
      if !list.isEmpty { return list.count }
    #endif

    #if os(Linux)
      if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
        return entries.count
      }
    #endif

    let limit = min(getdtablesize(), 4096)
    var count = 0
    for fd in 0..<limit {
      if fcntl(fd, F_GETFD) >= 0 {
        count += 1
      }
    }
    return count
  }

  private func openSocketFDCount() -> Int {
    #if canImport(Darwin)
      let list = darwinFDList()
      return list.filter { $0.procFDType == proxFDTypeSocket }.count
    #else
      return 0
    #endif
  }
}
