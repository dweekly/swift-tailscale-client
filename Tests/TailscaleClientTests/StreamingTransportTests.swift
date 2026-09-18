// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

final class StreamingTransportTests: XCTestCase {

  // MARK: - StreamingResponse Type Tests

  func testStreamingResponseExposesMetadataBeforeBody() async throws {
    let headers = ["Content-Type": "application/json", "Tailscale-Version": "1.96.0"]
    let bodyStream = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(Data("{\"hello\": \"world\"}\n".utf8))
      continuation.finish()
    }

    let response = StreamingResponse(
      statusCode: 200,
      headers: headers,
      body: bodyStream
    )

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.headers["Content-Type"], "application/json")
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "tailscale-version"), "1.96.0")
    XCTAssertEqual(response.value(forHeaderCaseInsensitive: "TAILSCALE-VERSION"), "1.96.0")
    XCTAssertNil(response.value(forHeaderCaseInsensitive: "nonexistent"))

    // Verify AsyncSequence conformance
    var receivedLines: [String] = []
    for try await line in response {
      receivedLines.append(String(decoding: line, as: UTF8.self))
    }
    XCTAssertEqual(receivedLines.count, 1)
    XCTAssertTrue(receivedLines[0].contains("hello"))
  }

  // MARK: - Unix Socket Streaming Tests

  #if canImport(Darwin) || os(Linux)
    func testUnixSocketStreamingDeliversResponseHead() async throws {
      let headAndBody =
        "HTTP/1.1 200 OK\r\n" +
        "Tailscale-Version: 1.98.0-custom\r\n" +
        "X-Custom-Header: stream-test\r\n" +
        "Content-Type: application/json\r\n\r\n" +
        "{\"Version\":\"1.98.0\"}\n"

      let server = try FaultUnixServer(behaviors: [
        .respond(headAndBody, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let transport = UnixSocketTransport(path: server.path)
      let request = TailscaleRequest(path: "/localapi/v0/watch-ipn-bus")

      let response = try await transport.sendStreaming(request, capabilityVersion: 1)
      XCTAssertEqual(response.statusCode, 200)
      XCTAssertEqual(response.value(forHeaderCaseInsensitive: "tailscale-version"), "1.98.0-custom")
      XCTAssertEqual(response.value(forHeaderCaseInsensitive: "x-custom-header"), "stream-test")

      var lines: [String] = []
      for try await line in response.body {
        lines.append(String(decoding: line, as: UTF8.self))
      }
      XCTAssertFalse(lines.isEmpty)
      XCTAssertTrue(lines[0].contains("Version"))
    }

    func testUnixSocketStreamingSurfacesNon200StatusWithoutThrowingTransportError() async throws {
      let errorResponse =
        "HTTP/1.1 403 Forbidden\r\n" +
        "Content-Type: text/plain\r\n" +
        "Content-Length: 12\r\n" +
        "Connection: close\r\n\r\n" +
        "access denied"

      let server = try FaultUnixServer(behaviors: [
        .respond(errorResponse, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let transport = UnixSocketTransport(path: server.path)
      let request = TailscaleRequest(path: "/localapi/v0/watch-ipn-bus")

      let response = try await transport.sendStreaming(request, capabilityVersion: 1)
      XCTAssertEqual(response.statusCode, 403)
      XCTAssertEqual(response.value(forHeaderCaseInsensitive: "content-type"), "text/plain")

      // Body can be drained without transport error
      var drained = Data()
      for try await chunk in response.body {
        drained.append(chunk)
      }
      XCTAssertEqual(String(decoding: drained, as: UTF8.self), "access denied")
    }
  #endif

  // MARK: - TailscaleClient watchIPNBus Metadata & Status Mapping Tests

  func testWatchIPNBusObservesDaemonVersion() async throws {
    let transport = MockTransport.scriptedStream(
      [.jsonLine("{\"Version\":\"1.100.0\"}")],
      statusCode: 200,
      headers: ["Tailscale-Version": "1.100.0-custom"]
    )
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport
    )
    let client = TailscaleClient(configuration: config)
    let initialDiag = await client.versionDiagnostics()
    XCTAssertNil(initialDiag.daemonVersion)

    let stream = try await client.watchIPNBus()
    for try await notify in stream {
      XCTAssertEqual(notify.version, "1.100.0")
      break
    }

    let diag = await client.versionDiagnostics()
    XCTAssertEqual(diag.daemonVersion, "1.100.0-custom")
  }

  func testWatchIPNBusSurfacesTypedStatusErrors() async throws {
    // 403 Forbidden -> .permissionDenied
    do {
      let transport = MockTransport.scriptedStream(
        [.line(Data("forbidden".utf8))],
        statusCode: 403,
        headers: ["Content-Type": "text/plain"]
      )
      let client = E2ETestSupport.makeClient(transport: transport)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.permissionDenied(let body, let endpoint) = error else {
          XCTFail("Expected .permissionDenied, got \(error)")
          return
        }
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "forbidden")
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      }
    }

    // 404 Not Found -> .endpointUnavailable
    do {
      let transport = MockTransport.scriptedStream(
        [.line(Data("not found".utf8))],
        statusCode: 404
      )
      let client = E2ETestSupport.makeClient(transport: transport)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.endpointUnavailable(let endpoint, let feature) = error else {
          XCTFail("Expected .endpointUnavailable, got \(error)")
          return
        }
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
        XCTAssertEqual(feature, "HasIPNBus")
      }
    }

    // 429 Rate Limited -> .rateLimited
    do {
      let transport = MockTransport.scriptedStream(
        [.line(Data("slow down".utf8))],
        statusCode: 429,
        headers: ["Retry-After": "15"]
      )
      let client = E2ETestSupport.makeClient(transport: transport)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.rateLimited(let retryAfter, _, let endpoint) = error else {
          XCTFail("Expected .rateLimited, got \(error)")
          return
        }
        XCTAssertEqual(retryAfter, 15.0)
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      }
    }

    // 500 Internal Server Error -> .unexpectedStatus
    do {
      let transport = MockTransport.scriptedStream(
        [.line(Data("crash".utf8))],
        statusCode: 500
      )
      let client = E2ETestSupport.makeClient(transport: transport)
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard case TailscaleClientError.unexpectedStatus(let code, let body, let endpoint) = error else {
          XCTFail("Expected .unexpectedStatus, got \(error)")
          return
        }
        XCTAssertEqual(code, 500)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "crash")
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
      }
    }
  }

  func testWatchIPNBusInjectsAuditReasonHeader() async throws {
    actor HeaderRecorder {
      var recordedHeaders: [String: String] = [:]
      func record(_ headers: [String: String]) {
        self.recordedHeaders = headers
      }
    }
    let recorder = HeaderRecorder()

    let transport = MockTransport.streaming { request, _ in
      await recorder.record(request.additionalHeaders)
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
    try await TailscaleClient.withAuditReason("audit-streaming-ticket-999") {
      let stream = try await client.watchIPNBus()
      for try await _ in stream {
        break
      }
    }

    let recorded = await recorder.recordedHeaders
    XCTAssertNotNil(recorded["X-Tailscale-Reason"])
    let decodedReason = Data(base64Encoded: recorded["X-Tailscale-Reason"] ?? "")
      .flatMap { String(data: $0, encoding: .utf8) }
    XCTAssertEqual(decodedReason, "audit-streaming-ticket-999")
  }

  // MARK: - MockTransport Scripting Tests

  func testMockTransportScriptedResponses() async throws {
    let scripts: [MockStreamingScript] = [
      MockStreamingScript(
        statusCode: 503,
        headers: ["Retry-After": "1"],
        events: [.line(Data("service unavailable".utf8))]
      ),
      MockStreamingScript(
        statusCode: 200,
        headers: ["Tailscale-Version": "1.96.0"],
        events: [.jsonLine("{\"Version\":\"1.96.0\"}")]
      ),
    ]

    let transport = MockTransport.scriptedResponses(scripts)
    let config = TailscaleClientConfiguration.default
    let req = TailscaleRequest(path: "/stream")

    // First attempt gets 503
    let resp1 = try await transport.sendStreaming(req, configuration: config)
    XCTAssertEqual(resp1.statusCode, 503)

    // Second attempt gets 200
    let resp2 = try await transport.sendStreaming(req, configuration: config)
    XCTAssertEqual(resp2.statusCode, 200)
    XCTAssertEqual(resp2.value(forHeaderCaseInsensitive: "tailscale-version"), "1.96.0")

    // Third attempt throws unimplemented
    do {
      _ = try await transport.sendStreaming(req, configuration: config)
      XCTFail("Expected unimplemented error after scripts exhausted")
    } catch let error as TailscaleTransportError {
      guard case .unimplemented = error else {
        XCTFail("Expected .unimplemented, got \(error)")
        return
      }
    }
  }

  // MARK: - Experimental logtap Tests

  func testExperimentalLogtapObservesVersionAndMapsNon200() async throws {
    let transport = MockTransport.scriptedStream(
      [.line(Data("unsupported".utf8))],
      statusCode: 404,
      headers: ["Tailscale-Version": "1.96.0"]
    )
    let client = E2ETestSupport.makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.experimental.logtap()) { error in
      guard case TailscaleClientError.endpointUnavailable(let endpoint, let feature) = error else {
        XCTFail("Expected .endpointUnavailable, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/logtap")
      XCTAssertEqual(feature, "Logtail")
    }

    let diag = await client.versionDiagnostics()
    XCTAssertEqual(diag.daemonVersion, "1.96.0")
  }
}
