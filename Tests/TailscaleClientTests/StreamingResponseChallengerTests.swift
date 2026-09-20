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

final class StreamingResponseChallengerTests: XCTestCase {

  override class func setUp() {
    super.setUp()
    #if canImport(Darwin) || os(Linux)
      signal(SIGPIPE, SIG_IGN)
    #endif
  }

  // MARK: - 1. Case-Insensitive Header Lookup

  func testHeaderLookupCaseInsensitivityExhaustive() {
    let headers: [String: String] = [
      "Tailscale-Version": "1.98.0-pre",
      "Content-Type": "application/json; charset=utf-8",
      "X-Custom-Header": "custom-value",
      "X-Empty-Header": "",
    ]

    let stream = AsyncThrowingStream<Data, Error> { $0.finish() }
    let response = StreamingResponse(
      statusCode: 200,
      headers: headers,
      body: stream
    )

    // Various casing forms of Tailscale-Version
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "Tailscale-Version"), "1.98.0-pre")
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "tailscale-version"), "1.98.0-pre")
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "TAILSCALE-VERSION"), "1.98.0-pre")
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "tAiLsCaLe-VeRsIoN"), "1.98.0-pre")
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "TAILSCALE-version"), "1.98.0-pre")

    // Content-Type casing
    XCTAssertEqual(
      response.value(forHeaderCaseInsensitive: "Content-Type"),
      "application/json; charset=utf-8"
    )
    XCTAssertEqual(
      response.value(forHeaderCaseInsensitive: "content-type"),
      "application/json; charset=utf-8"
    )
    XCTAssertEqual(
      response.value(forHeaderCaseInsensitive: "CONTENT-TYPE"),
      "application/json; charset=utf-8"
    )

    // Custom header casing
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "x-custom-header"), "custom-value")
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "X-CUSTOM-HEADER"), "custom-value")

    // Empty header
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "X-Empty-Header"), "")
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "x-empty-header"), "")

    // Non-existent headers
    XCTAssertNil(response.value(forHeaderCaseInsensitive: "nonexistent"))
    XCTAssertNil(response.value(forHeaderCaseInsensitive: ""))
    XCTAssertNil(response.value(forHeaderCaseInsensitive: "   "))
  }

  // MARK: - 2. Response Head Metadata Delivery Before Body Arrival

  func testHeadMetadataDeliveredBeforeBodyConsumingMock() async throws {
    actor StateBox {
      var bodyWasConsumed = false
      func markConsumed() { bodyWasConsumed = true }
      func isConsumed() -> Bool { bodyWasConsumed }
    }
    let state = StateBox()

    let (bodyStream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()

    let transport = MockTransport.streaming { _, _ in
      StreamingResponse(
        statusCode: 200,
        headers: [
          "Tailscale-Version": "1.96.2",
          "Content-Type": "text/plain",
        ],
        body: bodyStream
      )
    }

    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport
    )
    let request = TailscaleRequest(path: "/test/stream")

    let response = try await config.transport.sendStreaming(request, configuration: config)

    // Status code and headers must be available BEFORE any body iteration
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "tailscale-version"), "1.96.2")
    let consumedBefore = await state.isConsumed()
    XCTAssertFalse(consumedBefore)

    // Now yield body and verify consumption
    continuation.yield(Data("chunk1\n".utf8))
    continuation.finish()

    var collected: [String] = []
    for try await chunk in response {
      await state.markConsumed()
      collected.append(String(decoding: chunk, as: UTF8.self))
    }

    let consumedAfter = await state.isConsumed()
    XCTAssertTrue(consumedAfter)
    XCTAssertEqual(collected, ["chunk1\n"])
  }

  #if canImport(Darwin) || os(Linux)
    func testHeadMetadataDeliveredBeforeBodyConsumingLiveSocket() async throws {
      // Server sends head immediately, then delays 400ms before sending body
      let head =
        "HTTP/1.1 200 OK\r\n"
        + "Tailscale-Version: 1.99.1-challenger\r\n"
        + "Content-Type: application/json\r\n\r\n"
      let body = "{\"Version\":\"1.99.1\"}\n"

      let server = try DelayedBodyUnixServer(head: head, body: body, delayMs: 400)
      defer { server.stop() }

      let transport = UnixSocketTransport(path: server.path)
      let request = TailscaleRequest(path: "/localapi/v0/watch-ipn-bus")

      let start = ContinuousClock.now
      let response = try await transport.sendStreaming(request, capabilityVersion: 1)
      let elapsedForHead = ContinuousClock.now - start

      // Head must be delivered well before the 400ms body delay completes
      XCTAssertLessThan(
        elapsedForHead, .milliseconds(350),
        "Response head was blocked waiting for body chunks! Elapsed: \(elapsedForHead)"
      )
      XCTAssertEqual(response.statusCode, 200)
      XCTAssertEqual(
        response.value(forHeaderCaseInsensitive: "tailscale-version"),
        "1.99.1-challenger"
      )

      // Now consume body and verify line arrives after delay
      var received: [String] = []
      for try await line in response.body {
        received.append(String(decoding: line, as: UTF8.self))
      }
      XCTAssertFalse(received.isEmpty)
      XCTAssertTrue(received[0].contains("1.99.1"))
    }
  #endif

  // MARK: - 3. Live Socket and Mock Status Code Injection (200, 401, 403, 404, 429, 500, 503)

  func testStatusCode200SuccessMock() async throws {
    let transport = MockTransport.scriptedStream(
      [.jsonLine("{\"Version\":\"1.97.0\"}")],
      statusCode: 200,
      headers: ["Tailscale-Version": "1.97.0"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)
    let stream = try await client.watchIPNBus()
    var count = 0
    for try await notify in stream {
      XCTAssertEqual(notify.version, "1.97.0")
      count += 1
      break
    }
    XCTAssertEqual(count, 1)
  }

  #if canImport(Darwin) || os(Linux)
    func testStatusCode200SuccessLiveSocket() async throws {
      let raw =
        "HTTP/1.1 200 OK\r\n"
        + "Tailscale-Version: 1.97.1-socket\r\n"
        + "Content-Type: application/json\r\n\r\n"
        + "{\"Version\":\"1.97.1-socket\"}\n"

      let server = try FaultUnixServer(behaviors: [
        .respond(raw, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let client = makeSocketClient(path: server.path)
      let stream = try await client.watchIPNBus()
      var count = 0
      for try await notify in stream {
        XCTAssertEqual(notify.version, "1.97.1-socket")
        count += 1
        break
      }
      XCTAssertEqual(count, 1)
    }
  #endif

  func testStatusCode401UnauthorizedMock() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("auth token invalid".utf8))],
      statusCode: 401,
      headers: ["Content-Type": "text/plain"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, let body, let endpoint) = error
      else {
        XCTFail("Expected .unexpectedStatus(401), got: \(error)")
        return
      }
      XCTAssertEqual(code, 401)
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "auth token invalid")
      XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      // Verify classification is fatal
      XCTAssertEqual(StreamRetryPolicy.classify(error), .fatal)
    }
  }

  #if canImport(Darwin) || os(Linux)
    func testStatusCode401UnauthorizedLiveSocket() async throws {
      let raw =
        "HTTP/1.1 401 Unauthorized\r\n"
        + "Content-Type: text/plain\r\n"
        + "Content-Length: 17\r\n\r\n"
        + "unauthorized peer"

      let server = try FaultUnixServer(behaviors: [
        .respond(raw, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let client = makeSocketClient(path: server.path)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.unexpectedStatus(let code, let body, let endpoint) = error
        else {
          XCTFail("Expected .unexpectedStatus(401), got: \(error)")
          return
        }
        XCTAssertEqual(code, 401)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "unauthorized peer")
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
        XCTAssertEqual(StreamRetryPolicy.classify(error), .fatal)
      }
    }
  #endif

  func testStatusCode403ForbiddenMock() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("forbidden access".utf8))],
      statusCode: 403,
      headers: ["Content-Type": "text/plain"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.permissionDenied(let body, let endpoint) = error else {
        XCTFail("Expected .permissionDenied, got: \(error)")
        return
      }
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "forbidden access")
      XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      XCTAssertEqual(StreamRetryPolicy.classify(error), .fatal)
    }
  }

  #if canImport(Darwin) || os(Linux)
    func testStatusCode403ForbiddenLiveSocket() async throws {
      let raw =
        "HTTP/1.1 403 Forbidden\r\n"
        + "Content-Type: text/plain\r\n"
        + "Content-Length: 16\r\n\r\n"
        + "permission error"

      let server = try FaultUnixServer(behaviors: [
        .respond(raw, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let client = makeSocketClient(path: server.path)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.permissionDenied(let body, let endpoint) = error else {
          XCTFail("Expected .permissionDenied, got: \(error)")
          return
        }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "permission error")
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
        XCTAssertEqual(StreamRetryPolicy.classify(error), .fatal)
      }
    }
  #endif

  func testStatusCode404NotFoundMock() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("endpoint not found".utf8))],
      statusCode: 404
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.endpointUnavailable(let endpoint, let feature) = error else {
        XCTFail("Expected .endpointUnavailable, got: \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      XCTAssertEqual(feature, "HasIPNBus")
      XCTAssertEqual(StreamRetryPolicy.classify(error), .fatal)
    }
  }

  #if canImport(Darwin) || os(Linux)
    func testStatusCode404NotFoundLiveSocket() async throws {
      let raw =
        "HTTP/1.1 404 Not Found\r\n"
        + "Content-Length: 14\r\n\r\n"
        + "page not found"

      let server = try FaultUnixServer(behaviors: [
        .respond(raw, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let client = makeSocketClient(path: server.path)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.endpointUnavailable(let endpoint, let feature) = error
        else {
          XCTFail("Expected .endpointUnavailable, got: \(error)")
          return
        }
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
        XCTAssertEqual(feature, "HasIPNBus")
        XCTAssertEqual(StreamRetryPolicy.classify(error), .fatal)
      }
    }
  #endif

  func testStatusCode429RateLimitedSecondsMockAndSocket() async throws {
    // Mock
    let transport = MockTransport.scriptedStream(
      [.line(Data("rate limit exceeded".utf8))],
      statusCode: 429,
      headers: ["Retry-After": "45"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.rateLimited(let retryAfter, let body, let endpoint) = error
      else {
        XCTFail("Expected .rateLimited, got: \(error)")
        return
      }
      XCTAssertEqual(retryAfter, 45.0)
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "rate limit exceeded")
      XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      XCTAssertEqual(StreamRetryPolicy.classify(error), .retryable)
    }

    #if canImport(Darwin) || os(Linux)
      // Live Socket
      let raw =
        "HTTP/1.1 429 Too Many Requests\r\n"
        + "Retry-After: 90\r\n"
        + "Content-Length: 14\r\n\r\n"
        + "too many calls"

      let server = try FaultUnixServer(behaviors: [
        .respond(raw, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let socketClient = makeSocketClient(path: server.path)
      await assertThrowsErrorAsync(try await socketClient.watchIPNBus()) { error in
        guard
          case TailscaleClientError.rateLimited(let retryAfter, let body, let endpoint) = error
        else {
          XCTFail("Expected .rateLimited from socket, got: \(error)")
          return
        }
        XCTAssertEqual(retryAfter, 90.0)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "too many calls")
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
        XCTAssertEqual(StreamRetryPolicy.classify(error), .retryable)
      }
    #endif
  }

  func testStatusCode429RateLimitedHttpDate() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("quota exhausted".utf8))],
      statusCode: 429,
      headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.rateLimited(let retryAfter, _, _) = error else {
        XCTFail("Expected .rateLimited, got: \(error)")
        return
      }
      XCTAssertNotNil(retryAfter)
      XCTAssertEqual(StreamRetryPolicy.classify(error), .retryable)
    }
  }

  func testStatusCode500InternalServerErrorMockAndSocket() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("daemon internal panic".utf8))],
      statusCode: 500
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, let body, let endpoint) = error
      else {
        XCTFail("Expected .unexpectedStatus(500), got: \(error)")
        return
      }
      XCTAssertEqual(code, 500)
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "daemon internal panic")
      XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      XCTAssertEqual(StreamRetryPolicy.classify(error), .retryable)
    }

    #if canImport(Darwin) || os(Linux)
      let raw =
        "HTTP/1.1 500 Internal Server Error\r\n"
        + "Content-Length: 14\r\n\r\n"
        + "backend crashed"

      let server = try FaultUnixServer(behaviors: [
        .respond(raw, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let socketClient = makeSocketClient(path: server.path)
      await assertThrowsErrorAsync(try await socketClient.watchIPNBus()) { error in
        guard case TailscaleClientError.unexpectedStatus(let code, let body, let endpoint) = error
        else {
          XCTFail("Expected .unexpectedStatus(500) from socket, got: \(error)")
          return
        }
        XCTAssertEqual(code, 500)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "backend crashed")
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
        XCTAssertEqual(StreamRetryPolicy.classify(error), .retryable)
      }
    #endif
  }

  func testStatusCode503ServiceUnavailableMockAndSocket() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("daemon starting up".utf8))],
      statusCode: 503
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, let body, let endpoint) = error
      else {
        XCTFail("Expected .unexpectedStatus(503), got: \(error)")
        return
      }
      XCTAssertEqual(code, 503)
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "daemon starting up")
      XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      XCTAssertEqual(StreamRetryPolicy.classify(error), .retryable)
    }

    #if canImport(Darwin) || os(Linux)
      let raw =
        "HTTP/1.1 503 Service Unavailable\r\n"
        + "Content-Length: 12\r\n\r\n"
        + "over capacity"

      let server = try FaultUnixServer(behaviors: [
        .respond(raw, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let socketClient = makeSocketClient(path: server.path)
      await assertThrowsErrorAsync(try await socketClient.watchIPNBus()) { error in
        guard case TailscaleClientError.unexpectedStatus(let code, let body, let endpoint) = error
        else {
          XCTFail("Expected .unexpectedStatus(503) from socket, got: \(error)")
          return
        }
        XCTAssertEqual(code, 503)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "over capacity")
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
        XCTAssertEqual(StreamRetryPolicy.classify(error), .retryable)
      }
    #endif
  }

  // MARK: - 4. Bounded Error Body Draining (64 KiB cap & OOM Protection)

  func testBoundedErrorBodyDrainingHugePayloadMock() async throws {
    // 200 chunks of 1024 bytes = 204,800 bytes (> 64 KiB)
    actor ChunkYieldTracker {
      var chunksYielded = 0
      func increment() { chunksYielded += 1 }
      func count() -> Int { chunksYielded }
    }
    let tracker = ChunkYieldTracker()

    let chunkPayload = Data(repeating: 0x45, count: 1024)
    let events: [Data] = Array(repeating: chunkPayload, count: 200)

    let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    let producer = Task {
      for d in events {
        if Task.isCancelled { break }
        continuation.yield(d)
        await tracker.increment()
        try? await Task.sleep(for: .milliseconds(2))
      }
      continuation.finish()
    }
    defer { producer.cancel() }

    let transport = MockTransport.streaming { _, _ in
      StreamingResponse(
        statusCode: 500,
        headers: ["Content-Type": "application/octet-stream"],
        body: stream
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, let body, _) = error else {
        XCTFail("Expected unexpectedStatus, got \(error)")
        return
      }
      XCTAssertEqual(code, 500)
      // Body must be capped at approximately 64 KiB (65536) + buffer limit
      XCTAssertGreaterThanOrEqual(body.count, 64 * 1024)
      XCTAssertLessThanOrEqual(body.count, 64 * 1024 + 2048)
    }

    // Give asynchronous tasks a beat to settle
    try await Task.sleep(for: .milliseconds(50))
    let totalYielded = await tracker.count()
    // It should NOT have yielded all 200 chunks, proving early iteration break
    XCTAssertLessThan(totalYielded, 150)
  }

  #if canImport(Darwin) || os(Linux)
    func testBoundedErrorBodyDrainingHugePayloadLiveSocket() async throws {
      // 256 KiB body sent over live socket on HTTP 500 with newlines
      let head =
        "HTTP/1.1 500 Internal Server Error\r\n"
        + "Content-Type: text/plain\r\n\r\n"
      var hugeBody = Data()
      let linePayload = Data(repeating: 0x58, count: 1023) + Data("\n".utf8)
      for _ in 0..<256 {
        hugeBody.append(linePayload)
      }

      let server = try LargeResponseUnixServer(head: head, body: hugeBody)
      defer { server.stop() }

      let client = makeSocketClient(path: server.path)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.unexpectedStatus(let code, let body, _) = error else {
          XCTFail("Expected unexpectedStatus from socket, got \(error)")
          return
        }
        XCTAssertEqual(code, 500)
        // Capped around 64 KiB, far below the 256 KiB written by server
        XCTAssertGreaterThanOrEqual(body.count, 64 * 1024)
        XCTAssertLessThanOrEqual(body.count, 64 * 1024 + 4096)
      }
    }

    func testOversizedSingleLineErrorBodyOverSocketDocumentsCurrentBehavior() async throws {
      // If a hostile or malformed server sends 256 KiB with ZERO newlines,
      // NewlineFramer accumulates in buffer until EOF, then yields a single 256 KiB chunk.
      // Because consumeBoundedErrorBody checks `data.count >= limit` AFTER appending the chunk,
      // the resulting error body contains the entire 256 KiB chunk.
      let head =
        "HTTP/1.1 500 Internal Server Error\r\n"
        + "Content-Type: text/plain\r\n\r\n"
      let singleLineHugeBody = Data(repeating: 0x59, count: 256 * 1024)

      let server = try LargeResponseUnixServer(head: head, body: singleLineHugeBody)
      defer { server.stop() }

      let client = makeSocketClient(path: server.path)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.unexpectedStatus(let code, let body, _) = error else {
          XCTFail("Expected unexpectedStatus, got \(error)")
          return
        }
        XCTAssertEqual(code, 500)
        // Documents that a single undivided chunk is preserved without post-append truncation
        XCTAssertEqual(body.count, 256 * 1024)
      }
    }
  #endif

  func testBoundedErrorBodyDrainingInfiniteStreamTerminatesPromptly() async throws {
    // An infinite stream yielding 1024-byte chunks
    let (infiniteStream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()

    let task = Task.detached {
      let chunk = Data(repeating: 0x41, count: 1024)
      while !Task.isCancelled {
        continuation.yield(chunk)
        try? await Task.sleep(for: .milliseconds(1))
      }
    }
    defer {
      task.cancel()
      continuation.finish()
    }

    let transport = MockTransport.streaming { _, _ in
      StreamingResponse(
        statusCode: 500,
        headers: [:],
        body: infiniteStream
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    let start = ContinuousClock.now
    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, let body, _) = error else {
        XCTFail("Expected unexpectedStatus, got \(error)")
        return
      }
      XCTAssertEqual(code, 500)
      XCTAssertGreaterThanOrEqual(body.count, 64 * 1024)
      XCTAssertLessThanOrEqual(body.count, 64 * 1024 + 2048)
    }
    let elapsed = ContinuousClock.now - start
    // Must terminate within a reasonable window, not hang forever
    XCTAssertLessThan(elapsed, .seconds(1))
  }

  // MARK: - 5. Task-Local X-Tailscale-Reason Header Injection in Streaming Requests

  func testAuditReasonHeaderInjectedInStreamingRequests() async throws {
    actor HeaderCapture {
      var headers: [String: String] = [:]
      func set(_ h: [String: String]) { headers = h }
      func get() -> [String: String] { headers }
    }
    let capture = HeaderCapture()

    let transport = MockTransport.streaming { req, _ in
      await capture.set(req.additionalHeaders)
      return StreamingResponse(
        statusCode: 200,
        headers: [:],
        body: AsyncThrowingStream { continuation in
          continuation.yield(Data("{\"Version\":\"1.0\"}\n".utf8))
          continuation.finish()
        }
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    try await TailscaleClient.withAuditReason("incident-stream-audit-101") {
      let stream = try await client.watchIPNBus()
      for try await _ in stream { break }
    }

    let headers = await capture.get()
    XCTAssertNotNil(headers["X-Tailscale-Reason"])
    let decoded = Data(base64Encoded: headers["X-Tailscale-Reason"] ?? "")
      .flatMap { String(data: $0, encoding: .utf8) }
    XCTAssertEqual(decoded, "incident-stream-audit-101")
  }

  func testAuditReasonAbsentWhenUnsetOrEmpty() async throws {
    actor HeaderCapture {
      var headers: [String: String] = [:]
      func set(_ h: [String: String]) { headers = h }
      func get() -> [String: String] { headers }
    }
    let capture = HeaderCapture()

    let transport = MockTransport.streaming { req, _ in
      await capture.set(req.additionalHeaders)
      return StreamingResponse(
        statusCode: 200,
        headers: [:],
        body: AsyncThrowingStream { continuation in
          continuation.yield(Data("{\"Version\":\"1.0\"}\n".utf8))
          continuation.finish()
        }
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    // Unset
    let stream1 = try await client.watchIPNBus()
    for try await _ in stream1 { break }
    var headers = await capture.get()
    XCTAssertNil(headers["X-Tailscale-Reason"])

    // Empty string
    try await TailscaleClient.withAuditReason("") {
      let stream2 = try await client.watchIPNBus()
      for try await _ in stream2 { break }
    }
    headers = await capture.get()
    XCTAssertNil(headers["X-Tailscale-Reason"])
  }

  func testAuditReasonConcurrentIsolationAcrossTasks() async throws {
    actor ResultStore {
      var results: [String: String] = [:]
      func record(key: String, reason: String?) { results[key] = reason }
      func get() -> [String: String] { results }
    }
    let store = ResultStore()

    let transport = MockTransport.streaming { req, _ in
      let headerVal = req.additionalHeaders["X-Tailscale-Reason"]
      let decoded = headerVal.flatMap { Data(base64Encoded: $0) }
        .flatMap { String(data: $0, encoding: .utf8) }

      return StreamingResponse(
        statusCode: 200,
        headers: [:],
        body: AsyncThrowingStream { continuation in
          // Echo decoded reason in body using capitalized "Version" key
          continuation.yield(Data("{\"Version\":\"\(decoded ?? "none")\"}\n".utf8))
          continuation.finish()
        }
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await TailscaleClient.withAuditReason("alpha-coroutine-reason") {
          let s = try await client.watchIPNBus()
          for try await item in s {
            await store.record(key: "alpha", reason: item.version)
            break
          }
        }
      }

      group.addTask {
        try await TailscaleClient.withAuditReason("beta-coroutine-reason") {
          let s = try await client.watchIPNBus()
          for try await item in s {
            await store.record(key: "beta", reason: item.version)
            break
          }
        }
      }

      try await group.waitForAll()
    }

    let map = await store.get()
    XCTAssertEqual(map["alpha"], "alpha-coroutine-reason")
    XCTAssertEqual(map["beta"], "beta-coroutine-reason")
  }

  #if canImport(Darwin) || os(Linux)
    func testAuditReasonTransmittedOnWireLiveUnixSocket() async throws {
      let server = try RequestRecordingUnixServer(
        response: "HTTP/1.1 200 OK\r\n\r\n{\"Version\":\"1.0\"}\n")
      defer { server.stop() }

      let client = makeSocketClient(path: server.path)

      try await TailscaleClient.withAuditReason("audit-wire-live-2026") {
        let stream = try await client.watchIPNBus()
        for try await _ in stream { break }
      }

      // Verify the raw wire request received by the socket server
      let rawRequest = try await server.waitForRecordedRequest()
      XCTAssertTrue(
        rawRequest.contains("X-Tailscale-Reason: YXVkaXQtd2lyZS1saXZlLTIwMjY=\r\n"),
        "Raw HTTP request did not include base64-encoded X-Tailscale-Reason header! Raw request:\n\(rawRequest)"
      )
    }
  #endif

  // MARK: - 6. Version Diagnostics Reflection from Streaming Response Headers

  func testVersionDiagnosticsObservedFrom200Stream() async throws {
    let transport = MockTransport.scriptedStream(
      [.jsonLine("{\"Version\":\"1.92.0\"}")],
      statusCode: 200,
      headers: ["Tailscale-Version": "1.92.0-stable"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)
    let initialDiag = await client.versionDiagnostics()
    XCTAssertNil(initialDiag.daemonVersion)

    let stream = try await client.watchIPNBus()
    for try await _ in stream { break }

    let finalDiag = await client.versionDiagnostics()
    XCTAssertEqual(finalDiag.daemonVersion, "1.92.0-stable")
  }

  func testVersionDiagnosticsObservedFromErrorStream() async throws {
    // 403 Forbidden with Tailscale-Version header
    let transport = MockTransport.scriptedStream(
      [.line(Data("denied".utf8))],
      statusCode: 403,
      headers: ["Tailscale-Version": "1.93.5-error-stream"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard case TailscaleClientError.permissionDenied = error else {
        XCTFail("Expected permissionDenied, got \(error)")
        return
      }
    }

    // Diagnostics must still record the observed daemon version!
    let diag = await client.versionDiagnostics()
    XCTAssertEqual(diag.daemonVersion, "1.93.5-error-stream")
  }

  func testVersionDiagnosticsCaseInsensitiveHeader() async throws {
    let transport = MockTransport.scriptedStream(
      [.jsonLine("{\"Version\":\"1.94.0\"}")],
      statusCode: 200,
      headers: ["tAiLsCaLe-VeRsIoN": "1.94.0-casing"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    let stream = try await client.watchIPNBus()
    for try await _ in stream { break }

    let diag = await client.versionDiagnostics()
    XCTAssertEqual(diag.daemonVersion, "1.94.0-casing")
  }

  func testVersionDiagnosticsEmptyHeaderIgnored() async throws {
    let scripts: [MockStreamingScript] = [
      MockStreamingScript(
        statusCode: 200,
        headers: ["Tailscale-Version": "1.95.0-initial"],
        events: [.jsonLine("{\"Version\":\"1.95.0\"}")]
      ),
      MockStreamingScript(
        statusCode: 200,
        headers: ["Tailscale-Version": ""],
        events: [.jsonLine("{\"Version\":\"1.95.0\"}")]
      ),
    ]

    let transport = MockTransport.scriptedResponses(scripts)
    let client = E2ETestSupport.makeClient(transport: transport)

    let stream1 = try await client.watchIPNBus()
    for try await _ in stream1 { break }
    let diag1 = await client.versionDiagnostics()
    XCTAssertEqual(diag1.daemonVersion, "1.95.0-initial")

    let stream2 = try await client.watchIPNBus()
    for try await _ in stream2 { break }
    // Must NOT be cleared or overwritten by empty string
    let diag2 = await client.versionDiagnostics()
    XCTAssertEqual(diag2.daemonVersion, "1.95.0-initial")
  }

  // MARK: - 7. Direct UnixSocketTransport.sendStreaming Wire Test

  #if canImport(Darwin) || os(Linux)
    func testDirectUnixSocketTransportSendStreaming() async throws {
      let raw =
        "HTTP/1.1 200 OK\r\n"
        + "Tailscale-Version: 1.96.0-wire\r\n"
        + "Content-Type: application/json\r\n\r\n"
        + "{\"Version\":\"1.96.0\"}\n"

      let server = try FaultUnixServer(behaviors: [
        .respond(raw, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let transport = UnixSocketTransport(path: server.path)
      let request = TailscaleRequest(path: "/localapi/v0/watch-ipn-bus")

      let streamingResponse = try await transport.sendStreaming(request, capabilityVersion: 1)
      XCTAssertEqual(streamingResponse.statusCode, 200)
      XCTAssertEqual(
        streamingResponse.value(forHeaderCaseInsensitive: "tailscale-version"),
        "1.96.0-wire"
      )

      var lines: [String] = []
      for try await line in streamingResponse {
        lines.append(String(decoding: line, as: UTF8.self))
      }
      XCTAssertEqual(lines.count, 1)
      XCTAssertTrue(lines[0].contains("1.96.0"))
    }
  #endif

  // MARK: - Test Helpers

  private func makeSocketClient(path: String) -> TailscaleClient {
    let config = TailscaleClientConfiguration(
      endpoint: .unixSocket(path: path),
      authToken: nil,
      capabilityVersion: 1,
      transport: URLSessionTailscaleTransport()
    )
    return TailscaleClient(configuration: config)
  }
}

// MARK: - Test Socket Servers

#if canImport(Darwin) || os(Linux)

  /// A test Unix domain socket server that delays body delivery.
  final class DelayedBodyUnixServer: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false

    init(head: String, body: String, delayMs: UInt32) throws {
      self.path = NSTemporaryDirectory() + "delayed-\(UUID().uuidString.prefix(8)).sock"
      let fd = socket(AF_UNIX, Self.streamType, 0)
      guard fd >= 0 else { throw POSIXError(.EIO) }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
      withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        let base = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
        _ = strncpy(base, path, maxLength - 1)
      }
      let size = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
      }
      guard bound == 0, listen(fd, 2) == 0 else {
        close(fd)
        throw POSIXError(.EIO)
      }
      self.listenFD = fd

      let thread = Thread {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { return }

        #if canImport(Darwin)
          var one: Int32 = 1
          setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        // Drain request
        var buf = [UInt8](repeating: 0, count: 2048)
        _ = read(clientFD, &buf, buf.count)

        // Send head immediately
        head.utf8CString.withUnsafeBufferPointer { p in
          _ = write(clientFD, p.baseAddress, p.count - 1)
        }

        // Delay body delivery
        usleep(delayMs * 1000)

        // Send body
        body.utf8CString.withUnsafeBufferPointer { p in
          _ = write(clientFD, p.baseAddress, p.count - 1)
        }

        close(clientFD)
      }
      thread.start()
    }

    func stop() {
      lock.lock()
      defer { lock.unlock() }
      if !stopped {
        stopped = true
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
      }
    }

    deinit { stop() }

    private static var streamType: Int32 {
      #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
      #else
        return SOCK_STREAM
      #endif
    }
  }

  /// A test Unix domain socket server that delivers large bodies (>64 KiB) in a loop.
  final class LargeResponseUnixServer: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false

    init(head: String, body: Data) throws {
      self.path = NSTemporaryDirectory() + "large-\(UUID().uuidString.prefix(8)).sock"
      let fd = socket(AF_UNIX, Self.streamType, 0)
      guard fd >= 0 else { throw POSIXError(.EIO) }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
      withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        let base = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
        _ = strncpy(base, path, maxLength - 1)
      }
      let size = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
      }
      guard bound == 0, listen(fd, 2) == 0 else {
        close(fd)
        throw POSIXError(.EIO)
      }
      self.listenFD = fd

      let thread = Thread {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { return }

        #if canImport(Darwin)
          var one: Int32 = 1
          setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var buf = [UInt8](repeating: 0, count: 2048)
        _ = read(clientFD, &buf, buf.count)

        // Write head
        head.utf8CString.withUnsafeBufferPointer { p in
          _ = write(clientFD, p.baseAddress, p.count - 1)
        }

        // Write entire body in a loop (handling potential socket buffer full or client early close)
        var totalWritten = 0
        body.withUnsafeBytes { raw in
          let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
          while totalWritten < body.count {
            let toWrite = body.count - totalWritten
            let n = write(clientFD, ptr + totalWritten, toWrite)
            if n <= 0 { break }
            totalWritten += n
          }
        }

        close(clientFD)
      }
      thread.start()
    }

    func stop() {
      lock.lock()
      defer { lock.unlock() }
      if !stopped {
        stopped = true
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
      }
    }

    deinit { stop() }

    private static var streamType: Int32 {
      #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
      #else
        return SOCK_STREAM
      #endif
    }
  }

  actor RequestStore {
    var request: String?
    func set(_ r: String) { request = r }
    func get() -> String? { request }
  }

  /// A test Unix domain socket server that records the raw HTTP request bytes sent by client.
  final class RequestRecordingUnixServer: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    let store = RequestStore()

    init(response: String) throws {
      self.path = NSTemporaryDirectory() + "rec-\(UUID().uuidString.prefix(8)).sock"
      let fd = socket(AF_UNIX, Self.streamType, 0)
      guard fd >= 0 else { throw POSIXError(.EIO) }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
      withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        let base = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
        _ = strncpy(base, path, maxLength - 1)
      }
      let size = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
      }
      guard bound == 0, listen(fd, 2) == 0 else {
        close(fd)
        throw POSIXError(.EIO)
      }
      self.listenFD = fd

      let store = self.store
      let thread = Thread {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { return }

        #if canImport(Darwin)
          var one: Int32 = 1
          setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(clientFD, &buf, buf.count)
        if n > 0 {
          let reqData = Data(buf[0..<n])
          if let text = String(data: reqData, encoding: .utf8) {
            Task { await store.set(text) }
          }
        }

        response.utf8CString.withUnsafeBufferPointer { p in
          _ = write(clientFD, p.baseAddress, p.count - 1)
        }

        close(clientFD)
      }
      thread.start()
    }

    func waitForRecordedRequest(timeoutSeconds: Double = 3.0) async throws -> String {
      let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
      while ContinuousClock.now < deadline {
        if let req = await store.get() {
          return req
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw POSIXError(.ETIMEDOUT)
    }

    func stop() {
      lock.lock()
      defer { lock.unlock() }
      if !stopped {
        stopped = true
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
      }
    }

    deinit { stop() }

    private static var streamType: Int32 {
      #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
      #else
        return SOCK_STREAM
      #endif
    }
  }

#endif
