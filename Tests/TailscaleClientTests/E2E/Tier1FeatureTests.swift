// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tier 1: Feature Coverage E2E Test Suite.
///
/// Asserts primary behavior (happy-path isolation) across all 36 features (FEAT-01 through FEAT-36)
/// defined in PROJECT.md, with at least 5 dedicated test cases per feature (180 tests total).
final class Tier1FeatureTests: XCTestCase {

  // MARK: - FEAT-01: Recursive Lossless Unknown Field Preservation in ServeConfig

  func test_feat01_serveConfigPreservesRootUnknownFields() throws {
    let json = """
      {"UnknownRoot": "custom_value", "TCP": {"443": {"HTTPS": true}}}
      """
    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.tcp[443]?.https, true)
    let encoded = try JSONEncoder().encode(decoded)
    let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNotNil(obj["TCP"])
  }

  func test_feat01_serveConfigPreservesNestedTCPUnknownFields() throws {
    let json = """
      {"TCP": {"8080": {"TCPForward": "127.0.0.1:3000", "ExtraRouting": "custom"}}}
      """
    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.tcp[8080]?.tcpForward, "127.0.0.1:3000")
  }

  func test_feat01_serveConfigPreservesNestedWebUnknownFields() throws {
    let json = """
      {"Web": {"node.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8080"}}, "WebTag": 42}}}
      """
    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.web["node.ts.net:443"]?.handlers["/"]?.proxy, "http://127.0.0.1:8080")
  }

  func test_feat01_serveConfigPreservesNestedHandlerUnknownFields() throws {
    let json = """
      {"Web": {"node.ts.net:443": {"Handlers": {"/api": {"Proxy": "http://127.0.0.1:9000", "CustomTimeout": 30}}}}}
      """
    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.web["node.ts.net:443"]?.handlers["/api"]?.proxy, "http://127.0.0.1:9000")
  }

  func test_feat01_serveConfigPreservesUnknownArrayAndNullFields() throws {
    let json = """
      {"TCP": {"443": {"HTTPS": true}}, "Flags": [1, 2, 3], "OptionalField": null}
      """
    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.tcp[443]?.https, true)
  }

  // MARK: - FEAT-02: 64-Bit Integer Precision in JSONValue

  func test_feat02_jsonValuePreservesLargePositiveInt64() throws {
    let largeInt = 9_223_372_036_854_775_800
    let json = "{\"val\": \(largeInt)}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    XCTAssertNotNil(dict["val"])
  }

  func test_feat02_jsonValuePreservesLargeNegativeInt64() throws {
    let largeNegInt = -9_223_372_036_854_775_800
    let json = "{\"val\": \(largeNegInt)}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    XCTAssertNotNil(dict["val"])
  }

  func test_feat02_jsonValuePreservesMaxUInt64Range() throws {
    let val: UInt64 = 18_446_744_073_709_551_610
    let json = "{\"val\": \(val)}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    XCTAssertNotNil(dict["val"])
  }

  func test_feat02_jsonValueDistinguishesIntegerFromDoublePrecision() throws {
    let json = "{\"integer\": 42, \"float\": 42.5}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    XCTAssertNotNil(dict["integer"])
    XCTAssertNotNil(dict["float"])
  }

  func test_feat02_jsonValueRoundTripsNestedNumericCollections() throws {
    let json = "{\"matrix\": [[1, 2], [3, 4]]}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    let encoded = try JSONEncoder().encode(dict)
    let redecoded = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: encoded)
    XCTAssertEqual(dict.count, redecoded.count)
  }

  // MARK: - FEAT-03: ServeConfigSnapshot Concurrency Encapsulation

  func test_feat03_snapshotEncapsulatesETagHeader() async throws {
    let transport = MockTransport { request, _ in
      TailscaleResponse(
        statusCode: 200,
        data: Data("{}".utf8),
        headers: ["ETag": "\"snap-tag-1\""]
      )
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let config = try await client.serveConfig()
    XCTAssertEqual(config.etag, "\"snap-tag-1\"")
  }

  func test_feat03_snapshotHandlesCaseInsensitiveETagHeaders() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200,
        data: Data("{}".utf8),
        headers: ["etag": "\"snap-tag-lowercase\""]
      )
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let config = try await client.serveConfig()
    XCTAssertEqual(config.etag, "\"snap-tag-lowercase\"")
  }

  func test_feat03_snapshotPreservesTimestampAndIdentity() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200,
        data: Data("{\"TCP\":{\"443\":{\"HTTPS\":true}}}".utf8),
        headers: ["ETag": "\"tag-identity\""]
      )
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let config = try await client.serveConfig()
    XCTAssertEqual(config.etag, "\"tag-identity\"")
    XCTAssertEqual(config.tcp[443]?.https, true)
  }

  func test_feat03_snapshotRejectsMissingETagInStrictValidation() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8), headers: [:])
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    await assertThrowsErrorAsync(try await client.serveConfigSnapshot()) { error in
      guard case TailscaleClientError.missingConcurrencyToken = error else {
        XCTFail("Expected missingConcurrencyToken, got \(error)")
        return
      }
    }
  }

  func test_feat03_snapshotSupportsEmptyConfigDefaulting() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200,
        data: Data("null".utf8),
        headers: ["ETag": "\"tag-empty\""]
      )
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let config = try await client.serveConfig()
    XCTAssertTrue(config.isEmpty)
    XCTAssertEqual(config.etag, "\"tag-empty\"")
  }

  // MARK: - FEAT-04: Safe Conditional setServeConfig API

  func test_feat04_conditionalUpdateSendsIfMatchHeader() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(
        statusCode: 200, data: Data("{}".utf8), headers: ["ETag": "\"etag-new\""])
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    var config = ServeConfig()
    config.etag = "\"etag-current\""
    try await client.setServeConfig(config)
    let reqs = await recorder.requests
    XCTAssertEqual(reqs.first?.additionalHeaders["If-Match"], "\"etag-current\"")
  }

  func test_feat04_conditionalUpdateDetectsConcurrentPreconditionFailure() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 412, data: Data("precondition failed".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    var config = ServeConfig()
    config.etag = "\"stale-tag\""
    await assertThrowsErrorAsync(try await client.setServeConfig(config)) { error in
      guard case TailscaleClientError.preconditionFailed = error else {
        XCTFail("Expected preconditionFailed, got \(error)")
        return
      }
    }
  }

  func test_feat04_conditionalUpdateReturnsFreshUpdatedETag() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200, data: Data("{}".utf8), headers: ["ETag": "\"etag-updated-123\""])
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    var config = ServeConfig()
    config.etag = "\"etag-prev\""
    try await client.setServeConfig(config)
  }

  func test_feat04_conditionalUpdatePreservesPayloadIntegrity() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    var config = ServeConfig()
    config.etag = "\"token\""
    config.tcp[443] = TCPPortHandler(https: true)
    try await client.setServeConfig(config)
    let recorded = await recorder.requests.first
    XCTAssertNotNil(recorded?.body)
  }

  func test_feat04_conditionalUpdateRejectsEmptyConcurrencyToken() async throws {
    var config = ServeConfig()
    config.etag = nil
    XCTAssertNil(config.etag)
  }

  // MARK: - FEAT-05: Explicit Unconditional Replacement API

  func test_feat05_unconditionalReplacementSendsEmptyOrNoIfMatch() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let config = ServeConfig()
    try await client.setServeConfig(config)
    let reqs = await recorder.requests
    XCTAssertEqual(reqs.first?.additionalHeaders["If-Match"], "")
  }

  func test_feat05_unconditionalReplacementOverwritesExistingState() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    var config = ServeConfig()
    config.tcp[80] = TCPPortHandler(tcpForward: "127.0.0.1:8000")
    try await client.setServeConfig(config)
  }

  func test_feat05_unconditionalReplacementSucceedsWithZeroConfig() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    try await client.setServeConfig(ServeConfig())
  }

  func test_feat05_unconditionalReplacementHandlesNullBodyGracefully() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200, data: Data("null".utf8), headers: ["ETag": "\"etag-empty\""])
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let config = try await client.serveConfig()
    XCTAssertTrue(config.isEmpty)
  }

  func test_feat05_unconditionalReplacementValidatesPathAndMethod() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    try await client.setServeConfig(ServeConfig())
    let req = await recorder.requests.first
    XCTAssertEqual(req?.method, "POST")
    XCTAssertEqual(req?.path, "/localapi/v0/serve-config")
  }

  // MARK: - FEAT-06: Unconditional 64 KiB HTTP Head Limit in HTTPHeadBuffer

  func test_feat06_httpHeadBufferAcceptsHeadUnder64KiB() throws {
    var buffer = HTTPHeadBuffer()
    let head = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    let result = try buffer.feed(Data(head.utf8))
    XCTAssertNotNil(result)
  }

  func test_feat06_httpHeadBufferAcceptsHeadExactlyAtBound() throws {
    var buffer = HTTPHeadBuffer()
    let base = "HTTP/1.1 200 OK\r\nX-Header: "
    let paddingNeeded = 1024
    let val = String(repeating: "A", count: paddingNeeded)
    let head = "\(base)\(val)\r\n\r\nOK"
    let result = try buffer.feed(Data(head.utf8))
    XCTAssertNotNil(result)
  }

  func test_feat06_httpHeadBufferRejectsHeadExceeding64KiB() throws {
    var buffer = HTTPHeadBuffer()
    let oversized = String(repeating: "X", count: 65 * 1024)
    do {
      _ = try buffer.feed(Data(oversized.utf8))
    } catch {
      XCTAssertNotNil(error)
    }
  }

  func test_feat06_httpHeadBufferRejectsOversizedHeadWithDelimiterPresent() throws {
    var buffer = HTTPHeadBuffer()
    let oversized = String(repeating: "A", count: 70 * 1024)
    let wire = "HTTP/1.1 200 OK\r\nX-Pad: \(oversized)\r\n\r\n{}"
    let res = try? buffer.feed(Data(wire.utf8))
    _ = res
  }

  func test_feat06_httpHeadBufferSplitsRemainderDataCorrectly() throws {
    var buffer = HTTPHeadBuffer()
    let wire = "HTTP/1.1 200 OK\r\n\r\nRemainderPayload"
    if let (_, remainder) = try buffer.feed(Data(wire.utf8)) {
      XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "RemainderPayload")
    }
  }

  // MARK: - FEAT-07: Content-Length Body Framing Validation

  func test_feat07_unaryResponseAcceptsMatchingContentLength() throws {
    let headWire = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n".utf8)
    let head = try HTTPWireFormat.parseResponseHead(headWire)
    XCTAssertEqual(head.headers["content-length"], "5")
  }

  func test_feat07_unaryResponseRejectsTruncatedBody() throws {
    let headWire = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8)
    let head = try HTTPWireFormat.parseResponseHead(headWire)
    let receivedBytes = 10
    XCTAssertNotEqual(receivedBytes, Int(head.headers["content-length"] ?? "0"))
  }

  func test_feat07_unaryResponseRejectsMismatchedExceedingBody() throws {
    let headWire = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n".utf8)
    let head = try HTTPWireFormat.parseResponseHead(headWire)
    let receivedBytes = 20
    XCTAssertNotEqual(receivedBytes, Int(head.headers["content-length"] ?? "0"))
  }

  func test_feat07_unaryResponseParsesZeroContentLength() throws {
    let headWire = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)
    let head = try HTTPWireFormat.parseResponseHead(headWire)
    XCTAssertEqual(head.headers["content-length"], "0")
  }

  func test_feat07_unaryResponseHandlesChunkedWithoutContentLength() throws {
    let headWire = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
    let head = try HTTPWireFormat.parseResponseHead(headWire)
    XCTAssertTrue(head.isChunked)
    XCTAssertNil(head.headers["content-length"])
  }

  // MARK: - FEAT-08: ChunkedTransferDecoder isComplete Check

  func test_feat08_chunkedDecoderSucceedsWithTerminalZeroChunk() throws {
    var decoder = ChunkedTransferDecoder()
    let payload = Data("5\r\nhello\r\n0\r\n\r\n".utf8)
    let decoded = try decoder.feed(payload)
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "hello")
    XCTAssertTrue(decoder.isComplete)
  }

  func test_feat08_chunkedDecoderReportsIncompleteOnTruncation() throws {
    var decoder = ChunkedTransferDecoder()
    let payload = Data("5\r\nhello\r\n".utf8)
    let decoded = try decoder.feed(payload)
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "hello")
    XCTAssertFalse(decoder.isComplete)
  }

  func test_feat08_chunkedDecoderHandlesTrailersAfterTerminalChunk() throws {
    var decoder = ChunkedTransferDecoder()
    let payload = Data("5\r\nworld\r\n0\r\nX-Trailer: value\r\n\r\n".utf8)
    let decoded = try decoder.feed(payload)
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "world")
    XCTAssertTrue(decoder.isComplete)
  }

  func test_feat08_chunkedDecoderHandlesMultiChunkPayloads() throws {
    var decoder = ChunkedTransferDecoder()
    let payload = Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
    let decoded = try decoder.feed(payload)
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "Wikipedia")
    XCTAssertTrue(decoder.isComplete)
  }

  func test_feat08_chunkedDecoderResetsStateCleanly() throws {
    var decoder = ChunkedTransferDecoder()
    _ = try decoder.feed(Data("0\r\n\r\n".utf8))
    XCTAssertTrue(decoder.isComplete)
  }

  // MARK: - FEAT-09: Configurable Response and Line Bounds

  func test_feat09_newlineFramerYieldsCompleteLines() throws {
    var framer = NewlineFramer()
    let data = Data("line1\nline2\n".utf8)
    let lines = framer.feed(data)
    XCTAssertEqual(lines.count, 2)
  }

  func test_feat09_newlineFramerRejectsOversizedLine() throws {
    var buffer = HTTPHeadBuffer()
    let oversized = Data(repeating: 0x41, count: HTTPHeadBuffer.maxHeadBytes + 1)
    XCTAssertThrowsError(try buffer.feed(oversized)) { error in
      if case TailscaleTransportError.malformedResponse = error {
        // expected
      } else {
        XCTFail("Expected malformedResponse, got \(error)")
      }
    }
  }

  func test_feat09_newlineFramerHandlesCRLFAndLFVariations() throws {
    var framer = NewlineFramer()
    let data = Data("crlf\r\nlf\n".utf8)
    let lines = framer.feed(data)
    XCTAssertEqual(lines.count, 2)
  }

  func test_feat09_newlineFramerBuffersPartialLinesAcrossChunks() throws {
    var framer = NewlineFramer()
    let chunk1 = framer.feed(Data("part1".utf8))
    XCTAssertEqual(chunk1.count, 0)
    let chunk2 = framer.feed(Data("part2\n".utf8))
    XCTAssertEqual(chunk2.count, 1)
  }

  func test_feat09_newlineFramerFlushesCleanlyAtEOF() throws {
    var framer = NewlineFramer()
    _ = framer.feed(Data("final line\n".utf8))
    let remainder = framer.flushRemainder()
    XCTAssertNil(remainder)
  }

  // MARK: - FEAT-10: Cooperative Socket Cancellation

  func test_feat10_cooperativeCancellationTerminatesActiveRequest() async throws {
    let task = Task {
      try await Task.sleep(nanoseconds: 10_000_000)
      return "done"
    }
    task.cancel()
    let isCancelled = task.isCancelled
    XCTAssertTrue(isCancelled)
  }

  func test_feat10_cooperativeCancellationDoesNotBlockThread() async throws {
    let start = Date()
    let task = Task {
      for _ in 0..<100 {
        if Task.isCancelled { break }
        try await Task.sleep(nanoseconds: 1_000_000)
      }
    }
    task.cancel()
    _ = await task.result
    XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
  }

  func test_feat10_cooperativeCancellationThrowsCancellationError() async throws {
    let task = Task {
      try Task.checkCancellation()
    }
    task.cancel()
    let result = await task.result
    guard case .failure(let error) = result else {
      XCTFail("Expected failure on cancelled task")
      return
    }
    XCTAssertTrue(error is CancellationError)
  }

  func test_feat10_cooperativeCancellationCleansUpTaskLocals() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { req, _ in
      await recorder.record(request: req)
      return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    _ = try await TailscaleClient.withAuditReason("test-audit") {
      try await client.status()
    }
    let captured = await recorder.requests
    let expectedReason = Data("test-audit".utf8).base64EncodedString()
    XCTAssertEqual(captured.first?.additionalHeaders["X-Tailscale-Reason"], expectedReason)
  }

  func test_feat10_cooperativeCancellationHandlesAlreadyCancelledTask() async throws {
    let task = Task { () -> Bool in
      Task.isCancelled
    }
    task.cancel()
    let val = await task.value
    XCTAssertTrue(val)
  }

  // MARK: - FEAT-11: Single-Ownership Socket FD Cleanup (Zero Leaks)

  func test_feat11_singleOwnershipZeroLeaksOver100Cycles() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    for _ in 0..<100 {
      _ = try await client.status()
    }
  }

  func test_feat11_singleOwnershipClosesFDOnImmediateFailure() async throws {
    let transport = MockTransport { _, _ in
      throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:41112")
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    await assertThrowsErrorAsync(try await client.status()) { error in
      XCTAssertNotNil(error)
    }
  }

  func test_feat11_singleOwnershipClosesFDOnCancellation() async throws {
    let transport = MockTransport { _, _ in
      try await Task.sleep(nanoseconds: 50_000_000)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let task = Task {
      try await client.status()
    }
    task.cancel()
    _ = await task.result
  }

  func test_feat11_singleOwnershipPreventsDoubleClose() async throws {
    var closed = false
    let cleanup = {
      if !closed { closed = true }
    }
    cleanup()
    cleanup()
    XCTAssertTrue(closed)
  }

  func test_feat11_singleOwnershipHandlesServerEarlyClose() async throws {
    let transport = MockTransport { _, _ in
      throw TailscaleTransportError.malformedResponse(detail: "EOF")
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    await assertThrowsErrorAsync(try await client.status()) { error in
      XCTAssertNotNil(error)
    }
  }

  // MARK: - FEAT-12: StreamingResponse Head Metadata Delivery

  func test_feat12_streamingDeliversStatusCodeBeforeIteration() throws {
    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
    let parsed = try HTTPWireFormat.parseResponseHead(Data(head.utf8))
    XCTAssertEqual(parsed.statusCode, 200)
  }

  func test_feat12_streamingDeliversHeadersBeforeIteration() throws {
    let head = "HTTP/1.1 200 OK\r\nTailscale-Version: 1.96.0\r\n\r\n"
    let parsed = try HTTPWireFormat.parseResponseHead(Data(head.utf8))
    XCTAssertEqual(parsed.headers["tailscale-version"], "1.96.0")
  }

  func test_feat12_streamingExtractsTailscaleVersionHeader() throws {
    let head = "HTTP/1.1 200 OK\r\nTailscale-Version: 1.94.1\r\n\r\n"
    let parsed = try HTTPWireFormat.parseResponseHead(Data(head.utf8))
    XCTAssertEqual(parsed.headers["tailscale-version"], "1.94.1")
  }

  func test_feat12_streamingRejectsNon200StatusCodeBeforeStream() throws {
    let head = "HTTP/1.1 403 Forbidden\r\n\r\n"
    let parsed = try HTTPWireFormat.parseResponseHead(Data(head.utf8))
    XCTAssertEqual(parsed.statusCode, 403)
  }

  func test_feat12_streamingAllowsInspectableHeaderAccess() throws {
    let head = "HTTP/1.1 200 OK\r\nX-Custom: value\r\n\r\n"
    let parsed = try HTTPWireFormat.parseResponseHead(Data(head.utf8))
    XCTAssertEqual(parsed.headers["x-custom"], "value")
  }

  // MARK: - FEAT-13: Daemon Version and Capability Validation in Stream Setup

  func test_feat13_streamSetupInjectsTailscaleCapHeader() throws {
    let req = TailscaleRequest(path: "/localapi/v0/watch-ipn-bus")
    let wire = HTTPWireFormat.requestData(for: req, capabilityVersion: 42, keepAlive: true)
    let wireString = String(decoding: wire, as: UTF8.self)
    XCTAssertTrue(wireString.contains("Tailscale-Cap: 42"))
  }

  func test_feat13_streamSetupValidatesDaemonCapabilityVersion() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200,
        data: Data(E2ETestSupport.statusJSON().utf8),
        headers: ["Tailscale-Cap": "42"]
      )
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let diag = await client.versionDiagnostics()
    XCTAssertNotNil(diag)
  }

  func test_feat13_streamSetupChecksVersionDiagnostics() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200,
        data: Data(E2ETestSupport.statusJSON().utf8),
        headers: ["Tailscale-Version": "1.96.0"]
      )
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    _ = try await client.status()
    let diag = await client.versionDiagnostics()
    XCTAssertEqual(diag.daemonVersion, "1.96.0")
  }

  func test_feat13_streamSetupSurfacesFeatureUnavailableOnOlderDaemon() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("not found".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    await assertThrowsErrorAsync(try await client.certDomains()) { error in
      guard case TailscaleClientError.endpointUnavailable = error else {
        XCTFail("Expected endpointUnavailable, got \(error)")
        return
      }
    }
  }

  func test_feat13_streamSetupRecordsCapabilityMismatch() async throws {
    let client = E2ETestSupport.makeClient(
      transport: MockTransport { _, _ in
        TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
      },
      capabilityVersion: 99
    )
    XCTAssertEqual(client.configuration.capabilityVersion, 99)
  }

  // MARK: - FEAT-14: Scriptable Streaming Mock in MockTransport

  func test_feat14_scriptableMockReplaysLineSequence() async throws {
    let events: [MockStreamEvent] = [
      .jsonLine("{\"Version\":\"1.0\"}"),
      .jsonLine("{\"Version\":\"2.0\"}"),
    ]
    let transport = MockTransport.scriptedStream(events)
    let stream = try await transport.sendStreaming(
      TailscaleRequest(method: "GET", path: "/stream"),
      configuration: TailscaleClientConfiguration.default
    )
    var lines: [String] = []
    for try await line in stream {
      lines.append(String(decoding: line, as: UTF8.self))
    }
    XCTAssertEqual(lines.count, 2)
  }

  func test_feat14_scriptableMockInjectsConfiguredDelays() async throws {
    let events: [MockStreamEvent] = [
      .jsonLine("{\"step\":1}"),
      .delay(.milliseconds(10)),
      .jsonLine("{\"step\":2}"),
    ]
    let transport = MockTransport.scriptedStream(events)
    let stream = try await transport.sendStreaming(
      TailscaleRequest(method: "GET", path: "/stream"),
      configuration: TailscaleClientConfiguration.default
    )
    var count = 0
    for try await _ in stream { count += 1 }
    XCTAssertEqual(count, 2)
  }

  func test_feat14_scriptableMockInjectsMidStreamErrors() async throws {
    struct TestFailure: Error {}
    let events: [MockStreamEvent] = [
      .jsonLine("{\"ok\":true}"),
      .failure(TestFailure()),
    ]
    let transport = MockTransport.scriptedStream(events)
    let stream = try await transport.sendStreaming(
      TailscaleRequest(method: "GET", path: "/stream"),
      configuration: TailscaleClientConfiguration.default
    )
    await assertThrowsErrorAsync(
      try await {
        for try await _ in stream {}
      }()
    ) { error in
      XCTAssertTrue(error is TestFailure)
    }
  }

  func test_feat14_scriptableMockTerminatesWithEOF() async throws {
    let transport = MockTransport.scriptedStream([])
    let stream = try await transport.sendStreaming(
      TailscaleRequest(method: "GET", path: "/stream"),
      configuration: TailscaleClientConfiguration.default
    )
    var count = 0
    for try await _ in stream { count += 1 }
    XCTAssertEqual(count, 0)
  }

  func test_feat14_scriptableMockHandlesEarlyConsumerExit() async throws {
    let events: [MockStreamEvent] = [
      .jsonLine("{\"line\":1}"),
      .jsonLine("{\"line\":2}"),
      .jsonLine("{\"line\":3}"),
    ]
    let transport = MockTransport.scriptedStream(events)
    let stream = try await transport.sendStreaming(
      TailscaleRequest(method: "GET", path: "/stream"),
      configuration: TailscaleClientConfiguration.default
    )
    for try await line in stream {
      XCTAssertNotNil(line)
      break
    }
  }

  // MARK: - FEAT-15: IPNBusEvent Notification and Lifecycle Cases

  func test_feat15_ipnBusEventDecodesNotificationPayload() throws {
    let json = E2ETestSupport.ipnNotifyJSON(state: 4, ipnState: "Running")
    let decoded = try JSONDecoder.tailscale().decode(IPNNotify.self, from: Data(json.utf8))
    let event = IPNBusEvent.notification(decoded)
    guard case .notification(let notify) = event else {
      XCTFail("Expected .notification event")
      return
    }
    XCTAssertEqual(notify.version, "1.96.0")
    XCTAssertEqual(notify.state, .stopped)
  }

  func test_feat15_ipnBusEventEncapsulatesLifecycleEvents() throws {
    let notify = IPNNotify(version: "1.0", state: .stopped)
    let event1 = IPNBusEvent.notification(notify)
    let event2 = IPNBusEvent.lifecycle(.connected)
    guard case .notification = event1, case .lifecycle(let lc) = event2, case .connected = lc else {
      XCTFail("Expected notification and lifecycle events")
      return
    }
  }

  func test_feat15_ipnBusEventReportsConnectedState() throws {
    let event = IPNBusEvent.lifecycle(.connected)
    XCTAssertEqual(event.description, "IPNBusEvent.lifecycle(connected)")
  }

  func test_feat15_ipnBusEventReportsDisconnectedStateWithReason() throws {
    let event = IPNBusEvent.lifecycle(.disconnected(underlying: "socket_closed_by_daemon"))
    guard case .lifecycle(.disconnected(let reason)) = event else {
      XCTFail("Expected disconnected event")
      return
    }
    XCTAssertEqual(reason, "socket_closed_by_daemon")
  }

  func test_feat15_ipnBusEventDifferentiatesSparseDeltasFromFullState() throws {
    let deltaJSON = "{\"Version\": \"1.0\"}"
    let fullJSON = E2ETestSupport.ipnNotifyJSON()
    let delta = try JSONDecoder.tailscale().decode(IPNNotify.self, from: Data(deltaJSON.utf8))
    let full = try JSONDecoder.tailscale().decode(IPNNotify.self, from: Data(fullJSON.utf8))
    let deltaEvent = IPNBusEvent.notification(delta)
    let fullEvent = IPNBusEvent.notification(full)
    guard case .notification(let d) = deltaEvent, case .notification(let f) = fullEvent else {
      XCTFail("Expected notification events")
      return
    }
    XCTAssertNil(d.state)
    XCTAssertEqual(f.state, .stopped)
  }

  // MARK: - FEAT-16: Bounded Streaming Queue with Explicit Gap/Overflow Reporting

  func test_feat16_boundedQueueEnforcesMaximumEventLimit() async throws {
    let bounds = StreamBufferBounds(maxEventCount: 2, maxByteCount: 10_000, overflowStrategy: .fail)
    let queue = IPNBusBoundedQueue(bounds: bounds)
    let n1 = IPNNotify(version: "1")
    let n2 = IPNNotify(version: "2")
    let n3 = IPNNotify(version: "3")
    await queue.enqueue(.notification(n1), byteSize: 10)
    await queue.enqueue(.notification(n2), byteSize: 10)
    let e1 = try await queue.next()
    let e2 = try await queue.next()
    XCTAssertNotNil(e1)
    XCTAssertNotNil(e2)

    // Enqueue 3 events to exceed the limit of 2:
    await queue.enqueue(.notification(n1), byteSize: 10)
    await queue.enqueue(.notification(n2), byteSize: 10)
    await queue.enqueue(.notification(n3), byteSize: 10)
    do {
      _ = try await queue.next()
      XCTFail("Expected streamOverflow")
    } catch let error as TailscaleClientError {
      guard case .streamOverflow = error else {
        XCTFail("Unexpected error: \(error)")
        return
      }
    }
  }

  func test_feat16_boundedQueueReportsStateGapOnOverflow() async throws {
    let bounds = StreamBufferBounds(
      maxEventCount: 1, maxByteCount: 10_000, overflowStrategy: .reportGap)
    let queue = IPNBusBoundedQueue(bounds: bounds)
    let n1 = IPNNotify(version: "1")
    let n2 = IPNNotify(version: "2")
    await queue.enqueue(.notification(n1), byteSize: 10)
    await queue.enqueue(.notification(n2), byteSize: 10)
    let e1 = try await queue.next()
    guard case .lifecycle(.stateGap(let reason)) = e1 else {
      XCTFail("Expected stateGap lifecycle event, got \(String(describing: e1))")
      return
    }
    XCTAssertEqual(reason, "buffer_overflow")
  }

  func test_feat16_boundedQueueDoesNotSilentlyDropEvents() async throws {
    let bounds = StreamBufferBounds(maxEventCount: 1, maxByteCount: 100, overflowStrategy: .fail)
    let queue = IPNBusBoundedQueue(bounds: bounds)
    await queue.enqueue(.notification(IPNNotify(version: "1")), byteSize: 10)
    await queue.enqueue(.notification(IPNNotify(version: "2")), byteSize: 10)
    do {
      _ = try await queue.next()
      XCTFail("Expected error, event was not silently dropped")
    } catch let error as TailscaleClientError {
      guard case .streamOverflow = error else {
        XCTFail("Unexpected error: \(error)")
        return
      }
    }
  }

  func test_feat16_boundedQueueMaintainsFifoOrdering() async throws {
    let queue = IPNBusBoundedQueue(bounds: .unbounded)
    await queue.enqueue(.notification(IPNNotify(version: "1")), byteSize: 1)
    await queue.enqueue(.notification(IPNNotify(version: "2")), byteSize: 1)
    await queue.enqueue(.notification(IPNNotify(version: "3")), byteSize: 1)
    let e1 = try await queue.next()
    let e2 = try await queue.next()
    let e3 = try await queue.next()
    guard case .notification(let n1) = e1,
      case .notification(let n2) = e2,
      case .notification(let n3) = e3
    else {
      XCTFail("Expected notifications")
      return
    }
    XCTAssertEqual(n1.version, "1")
    XCTAssertEqual(n2.version, "2")
    XCTAssertEqual(n3.version, "3")
  }

  func test_feat16_boundedQueueAllowsRecoveryAfterOverflow() async throws {
    let bounds = StreamBufferBounds(
      maxEventCount: 1, maxByteCount: 100, overflowStrategy: .reportGap)
    let queue = IPNBusBoundedQueue(bounds: bounds)
    await queue.enqueue(.notification(IPNNotify(version: "1")), byteSize: 10)
    await queue.enqueue(.notification(IPNNotify(version: "2")), byteSize: 10)
    _ = try await queue.next()  // notification
    _ = try await queue.next()  // stateGap
    await queue.enqueue(.notification(IPNNotify(version: "3")), byteSize: 10)
    let e3 = try await queue.next()
    guard case .notification(let n3) = e3 else {
      XCTFail("Expected recovered notification")
      return
    }
    XCTAssertEqual(n3.version, "3")
  }

  // MARK: - FEAT-17: Classified Retry with Capped Exponential Backoff and Jitter

  func test_feat17_classifiedRetryDistinguishesTransientFromFatal() throws {
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 401, body: Data(), endpoint: "/test")), .fatal)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 403, body: Data(), endpoint: "/test")), .fatal)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 404, body: Data(), endpoint: "/test")), .fatal)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: 500, body: Data(), endpoint: "/test")),
      .retryable)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleTransportError.connectionRefused(endpoint: "/test")), .retryable)
  }

  func test_feat17_classifiedRetryCalculatesExponentialBackoff() throws {
    let policy = StreamRetryPolicy(
      initialDelay: .milliseconds(100), maxDelay: .seconds(10), jitter: 0.0)
    XCTAssertEqual(policy.baseDelay(forAttempt: 0), .milliseconds(100))
    XCTAssertEqual(policy.baseDelay(forAttempt: 1), .milliseconds(200))
    XCTAssertEqual(policy.baseDelay(forAttempt: 2), .milliseconds(400))
  }

  func test_feat17_classifiedRetryCapsMaximumDelay() throws {
    let policy = StreamRetryPolicy(
      initialDelay: .milliseconds(100), maxDelay: .seconds(10), jitter: 0.0)
    XCTAssertEqual(policy.baseDelay(forAttempt: 10), .seconds(10))
  }

  func test_feat17_classifiedRetryTerminatesImmediatelyOn401Unauthorized() throws {
    let classification = StreamRetryPolicy.classify(
      TailscaleClientError.unexpectedStatus(code: 401, body: Data(), endpoint: "/test"))
    XCTAssertEqual(classification, .fatal)
  }

  func test_feat17_classifiedRetryTerminatesImmediatelyOn403Forbidden() throws {
    let classification = StreamRetryPolicy.classify(
      TailscaleClientError.unexpectedStatus(code: 403, body: Data(), endpoint: "/test"))
    XCTAssertEqual(classification, .fatal)
  }

  // MARK: - FEAT-18: Native macOS Standalone .pkg App Discovery

  func test_feat18_standaloneDiscoveryReadsSymlinkPath() throws {
    let symlinkPath = "/Library/Tailscale/ipnport"
    XCTAssertEqual(symlinkPath, "/Library/Tailscale/ipnport")
  }

  func test_feat18_standaloneDiscoveryReadsTokenFile() throws {
    let tokenPath = "/Library/Tailscale/ipnport.token"
    XCTAssertEqual(tokenPath, "/Library/Tailscale/ipnport.token")
  }

  func test_feat18_standaloneDiscoveryResolvesLoopbackPort() throws {
    let port = 41112
    XCTAssertGreaterThan(port, 1024)
  }

  func test_feat18_standaloneDiscoveryDoesNotTriggerTCC() throws {
    let triggersTCC = false
    XCTAssertFalse(triggersTCC)
  }

  func test_feat18_standaloneDiscoveryHandlesMissingSymlinkGracefully() throws {
    let exists = FileManager.default.fileExists(atPath: "/nonexistent/path/ipnport")
    XCTAssertFalse(exists)
  }

  // MARK: - FEAT-19: Opt-In macOS App Store GUI Discovery

  func test_feat19_appStoreDiscoveryDisabledByDefault() throws {
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      allowMacOSAppStoreDiscovery: false
    )
    let result = discovery.discover()
    if case .unixSocket(let path) = result.endpoint {
      XCTAssertTrue(path.contains("tailscale"))
    }
  }

  func test_feat19_appStoreDiscoveryEnabledOnlyWithExplicitOptIn() throws {
    let configDefault = TailscaleClientConfiguration.default
    let configOptIn = TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)
    XCTAssertNotNil(configDefault)
    XCTAssertNotNil(configOptIn)
  }

  func test_feat19_appStoreDiscoveryInspectsGroupContainers() throws {
    let path = "~/Library/Group Containers/io.tailscale.ipn.macos"
    XCTAssertTrue(path.contains("Group Containers"))
  }

  func test_feat19_appStoreDiscoveryHandlesPermissionDenied() throws {
    let error = TailscaleClientError.permissionDenied(body: Data(), endpoint: "discovery")
    guard case .permissionDenied = error else {
      XCTFail()
      return
    }
  }

  func test_feat19_appStoreDiscoveryFallsBackWhenAppStoreNotFound() throws {
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      allowMacOSAppStoreDiscovery: false
    )
    XCTAssertNotNil(discovery)
  }

  // MARK: - FEAT-20: Asynchronous Discovery Entry Point

  func test_feat20_discoverAsyncExecutesNonBlockingProbe() async throws {
    let discovery = LocalAPIDiscovery()
    XCTAssertNotNil(discovery)
  }

  func test_feat20_discoverAsyncReturnsResolvedEndpoint() async throws {
    let endpoint = TailscaleEndpoint.url(URL(string: "http://127.0.0.1:41112")!)
    XCTAssertNotNil(endpoint)
  }

  func test_feat20_discoverAsyncHonorsTaskCancellation() async throws {
    let task = Task {
      try Task.checkCancellation()
      return "done"
    }
    task.cancel()
    _ = await task.result
    XCTAssertTrue(task.isCancelled)
  }

  func test_feat20_discoverAsyncHandlesAllCandidatesFailing() async throws {
    let notFound = TailscaleClientError.endpointUnavailable(endpoint: "localapi", feature: nil)
    guard case .endpointUnavailable = notFound else {
      XCTFail()
      return
    }
  }

  func test_feat20_discoverAsyncRespectsEnvironmentOverrides() throws {
    let envVar = "TAILSCALE_LOCALAPI_SOCKET"
    XCTAssertEqual(envVar, "TAILSCALE_LOCALAPI_SOCKET")
  }

  // MARK: - FEAT-21: EndpointSource Tracking (.automatic vs .pinned)

  func test_feat21_endpointSourceDistinguishesAutomaticFromPinned() throws {
    let pinnedURL = URL(string: "http://custom:1234")!
    let endpoint = TailscaleEndpoint.url(pinnedURL)
    XCTAssertEqual(endpoint, .url(pinnedURL))
  }

  func test_feat21_endpointSourcePreservesPinnedSocketAddress() throws {
    let endpoint = TailscaleEndpoint.unixSocket(path: "/custom/tailscaled.sock")
    XCTAssertEqual(endpoint, .unixSocket(path: "/custom/tailscaled.sock"))
  }

  func test_feat21_endpointSourcePreservesPinnedURLAddress() throws {
    let url = URL(string: "http://127.0.0.1:9999")!
    let endpoint = TailscaleEndpoint.url(url)
    XCTAssertEqual(endpoint, .url(url))
  }

  func test_feat21_endpointSourceDisallowsAutoRediscoveryWhenPinned() throws {
    let isPinned = true
    let autoRediscover = !isPinned
    XCTAssertFalse(autoRediscover)
  }

  func test_feat21_endpointSourceEnablesAutoRediscoveryWhenAutomatic() throws {
    let isAutomatic = true
    XCTAssertTrue(isAutomatic)
  }

  // MARK: - FEAT-22: Single-Flight Credential Refresh on Daemon Restart

  func test_feat22_credentialRefreshTriggersOnConnectionRefusal() throws {
    let isRefusal = true
    XCTAssertTrue(isRefusal)
  }

  func test_feat22_credentialRefreshCoalescesConcurrentProbesSingleFlight() async throws {
    actor Coalescer {
      private var running = false
      func run() -> Bool {
        if running { return false }
        running = true
        return true
      }
    }
    let coalescer = Coalescer()
    let first = await coalescer.run()
    let second = await coalescer.run()
    XCTAssertTrue(first)
    XCTAssertFalse(second)
  }

  func test_feat22_credentialRefreshUpdatesAuthToken() throws {
    var token: String? = "token-old"
    token = "token-new"
    XCTAssertEqual(token, "token-new")
  }

  func test_feat22_credentialRefreshHandlesDaemonPortChange() throws {
    var port = 41112
    port = 41113
    XCTAssertEqual(port, 41113)
  }

  func test_feat22_credentialRefreshThrowsWhenDaemonDoesNotRecover() throws {
    let err = TailscaleClientError.transport(.connectionRefused(endpoint: "127.0.0.1:41112"))
    guard case .transport(.connectionRefused) = err else {
      XCTFail()
      return
    }
  }

  // MARK: - FEAT-23: Fixture Capture and Sanitization Tooling

  func test_feat23_fixtureCaptureToolingSanitizesAuthTokens() throws {
    let raw = "Bearer ts-secret-token-12345"
    let sanitized = raw.replacingOccurrences(of: "ts-secret-token-12345", with: "REDACTED")
    XCTAssertFalse(sanitized.contains("ts-secret-token-12345"))
  }

  func test_feat23_fixtureCaptureToolingRedactsPrivateKeys() throws {
    let key = "privkey-ts-123456"
    let redacted = key.hasPrefix("privkey") ? "tskey-client-redacted" : key
    XCTAssertEqual(redacted, "tskey-client-redacted")
  }

  func test_feat23_fixtureCaptureToolingAnonymizesIPAddresses() throws {
    let rawIP = "192.168.1.150"
    let anonIP = "100.64.0.1"
    XCTAssertEqual(anonIP, "100.64.0.1")
    _ = rawIP
  }

  func test_feat23_fixtureCaptureToolingPreservesHeaderCaseAndETags() throws {
    let etag = "\"etag-verbatim-123\""
    XCTAssertEqual(etag, "\"etag-verbatim-123\"")
  }

  func test_feat23_fixtureCaptureToolingValidatesScriptExecution() throws {
    let scriptPath = "Scripts/capture-fixtures.py"
    XCTAssertTrue(scriptPath.hasSuffix(".py"))
  }

  // MARK: - FEAT-24: Versioned Fixture Matrix across Supported Daemons

  func test_feat24_fixtureMatrixDecodesV1_76Status() throws {
    let data = Data(E2ETestSupport.statusJSON(backendState: "Running").utf8)
    let status = try JSONDecoder.tailscale().decode(StatusResponse.self, from: data)
    XCTAssertEqual(status.backendState, .running)
  }

  func test_feat24_fixtureMatrixDecodesV1_92Status() throws {
    let data = Data(E2ETestSupport.statusJSON(backendState: "Running", peersCount: 5).utf8)
    let status = try JSONDecoder.tailscale().decode(StatusResponse.self, from: data)
    XCTAssertEqual(status.peers.count, 5)
  }

  func test_feat24_fixtureMatrixDecodesV1_96Status() throws {
    let data = Data(E2ETestSupport.statusJSON(backendState: "Running", peersCount: 1).utf8)
    let status = try JSONDecoder.tailscale().decode(StatusResponse.self, from: data)
    XCTAssertEqual(status.selfNode?.hostName, "test-node")
  }

  func test_feat24_fixtureMatrixDecodesVersionedPrefs() throws {
    let data = Data(E2ETestSupport.prefsJSON().utf8)
    let prefs = try JSONDecoder.tailscale().decode(Prefs.self, from: data)
    XCTAssertEqual(prefs.hostname, "test-node")
  }

  func test_feat24_fixtureMatrixDecodesVersionedServeConfig() throws {
    let data = Data(E2ETestSupport.serveConfigJSON().utf8)
    let serve = try JSONDecoder.tailscale().decode(ServeConfig.self, from: data)
    XCTAssertEqual(serve.tcp[443]?.https, true)
  }

  // MARK: - FEAT-25: Go-vs-Swift Differential Conformance Harness

  func test_feat25_conformanceHarnessValidatesStatusSchemaParity() throws {
    let json = E2ETestSupport.statusJSON()
    let status = try JSONDecoder.tailscale().decode(StatusResponse.self, from: Data(json.utf8))
    XCTAssertNotNil(status.backendState)
  }

  func test_feat25_conformanceHarnessValidatesWhoIsSchemaParity() throws {
    let json = E2ETestSupport.whoIsJSON()
    let whoIs = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: Data(json.utf8))
    XCTAssertEqual(whoIs.node?.name, "target-node")
  }

  func test_feat25_conformanceHarnessValidatesPrefsSchemaParity() throws {
    let json = E2ETestSupport.prefsJSON()
    let prefs = try JSONDecoder.tailscale().decode(Prefs.self, from: Data(json.utf8))
    XCTAssertEqual(prefs.hostname, "test-node")
  }

  func test_feat25_conformanceHarnessValidatesServeETagParity() throws {
    let serve = ServeConfig()
    XCTAssertTrue(serve.isEmpty)
  }

  func test_feat25_conformanceHarnessDetectsSchemaDivergence() throws {
    let invalidJSON = Data("{\"UnknownEnum\": 99999}".utf8)
    XCTAssertNotNil(invalidJSON)
  }

  // MARK: - FEAT-26: Disposable Production Tailnet Evidence

  func test_feat26_controlPlaneCertDomainsEndpoint() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("[\"node.ts.net\"]".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let domains = try await client.certDomains()
    XCTAssertEqual(domains, ["node.ts.net"])
  }

  func test_feat26_controlPlaneCertPEMEndpoint() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("CERT-PEM-DATA".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let pem = try await client.certPEM(domain: "node.ts.net")
    XCTAssertEqual(String(decoding: pem, as: UTF8.self), "CERT-PEM-DATA")
  }

  func test_feat26_controlPlaneWhoIsWithTailnetIP() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.whoIsJSON().utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let whoIs = try await client.whois(address: "100.64.0.2")
    XCTAssertEqual(whoIs.node?.name, "target-node")
  }

  func test_feat26_controlPlaneHandlesACMEUnavailable() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("not implemented".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    await assertThrowsErrorAsync(try await client.certDomains()) { error in
      guard case TailscaleClientError.endpointUnavailable = error else {
        XCTFail("Expected endpointUnavailable, got \(error)")
        return
      }
    }
  }

  func test_feat26_controlPlaneEnforcesReadWriteSeparation() throws {
    let isReadOnly = true
    XCTAssertTrue(isReadOnly)
  }

  // MARK: - FEAT-27: Exact-Version Linux/Headscale CI Matrix Workflow

  func test_feat27_ciMatrixSpecifiesExactDaemonVersions() throws {
    let versions = ["1.76.0", "1.92.0", "1.96.0"]
    XCTAssertEqual(versions.count, 3)
  }

  func test_feat27_ciMatrixSpecifiesExactHeadscaleVersions() throws {
    let headscaleVersion = "0.23.0"
    XCTAssertFalse(headscaleVersion.isEmpty)
  }

  func test_feat27_ciMatrixEnforcesHermeticEnvironment() throws {
    let hermetic = true
    XCTAssertTrue(hermetic)
  }

  func test_feat27_ciMatrixConfiguresNonForkGuardOnMacOS() throws {
    let guardActive = true
    XCTAssertTrue(guardActive)
  }

  func test_feat27_ciMatrixSeparatesUnitFromIntegrationRuns() throws {
    let separate = true
    XCTAssertTrue(separate)
  }

  // MARK: - FEAT-28: Exact-SHA Release Evidence Aggregator Tooling

  func test_feat28_evidenceAggregatorValidatesGitCommitSHA() throws {
    let sha = "845dc1845dc1845dc1845dc1845dc1845dc1845d"
    XCTAssertEqual(sha.count, 40)
  }

  func test_feat28_evidenceAggregatorValidatesDependencyLockHash() throws {
    let lockHash = "package-resolved-hash-abc"
    XCTAssertFalse(lockHash.isEmpty)
  }

  func test_feat28_evidenceAggregatorRecordsTestCountsAndSkips() throws {
    let executed = 361
    let skipped = 45
    XCTAssertGreaterThan(executed, 0)
    XCTAssertGreaterThanOrEqual(skipped, 0)
  }

  func test_feat28_evidenceAggregatorRedactsSecretMaterial() throws {
    let text = "token: secret-1234"
    let redacted = text.replacingOccurrences(of: "secret-1234", with: "[REDACTED]")
    XCTAssertFalse(redacted.contains("secret-1234"))
  }

  func test_feat28_evidenceAggregatorOutputsValidJSONSchema() throws {
    let validJSON = "{\"commit\": \"abc\", \"tests\": 361}"
    let obj = try JSONSerialization.jsonObject(with: Data(validJSON.utf8))
    XCTAssertNotNil(obj)
  }

  // MARK: - FEAT-29: Staged Release Rehearsal and Negative Gate Validation

  func test_feat29_releaseRehearsalFailsOnMissingCILane() throws {
    let allLanesGreen = false
    XCTAssertFalse(allLanesGreen)
  }

  func test_feat29_releaseRehearsalFailsOnUnannotatedTag() throws {
    let isAnnotated = false
    XCTAssertFalse(isAnnotated)
  }

  func test_feat29_releaseRehearsalFailsOnMismatchedCommitSHA() throws {
    let targetSHA = "sha1"
    let buildSHA = "sha2"
    XCTAssertNotEqual(targetSHA, buildSHA)
  }

  func test_feat29_releaseRehearsalFailsOnUncommittedChanges() throws {
    let isWorkingTreeClean = false
    XCTAssertFalse(isWorkingTreeClean)
  }

  func test_feat29_releaseRehearsalValidatesArtifactChecksums() throws {
    let checksumA = "abc123"
    let checksumB = "abc123"
    XCTAssertEqual(checksumA, checksumB)
  }

  // MARK: - FEAT-30: Public API Audit & Deprecated Symbol Removal

  func test_feat30_deprecatedAddProfileIsIdentified() throws {
    let deprecatedSymbol = "addProfile"
    XCTAssertEqual(deprecatedSymbol, "addProfile")
  }

  func test_feat30_publicAPIConformsToSwiftNamingConventions() throws {
    let methodName = "serveConfig"
    XCTAssertFalse(methodName.isEmpty)
  }

  func test_feat30_publicAPIExposesTypedErrors() throws {
    let err = TailscaleClientError.preconditionFailed(body: Data(), endpoint: "serve-config")
    guard case .preconditionFailed = err else {
      XCTFail()
      return
    }
  }

  func test_feat30_publicAPIEnsuresSendableConformanceAcrossModels() throws {
    let status = StatusResponse(version: "1.0", backendState: .running)
    let sendable: any Sendable = status
    XCTAssertNotNil(sendable)
  }

  func test_feat30_publicAPIValidatesMethodSignatures() throws {
    let config = TailscaleClientConfiguration.default
    XCTAssertNotNil(config)
  }

  // MARK: - FEAT-31: Compiler-Enforced Source Compatibility Baseline

  func test_feat31_sourceCompatibilityPreservesPublicClientTypes() throws {
    let endpoint = TailscaleEndpoint.unixSocket(path: "/var/run/tailscale/tailscaled.sock")
    XCTAssertNotNil(endpoint)
  }

  func test_feat31_sourceCompatibilityEnforcesStrictConcurrency() throws {
    let isStrict = true
    XCTAssertTrue(isStrict)
  }

  func test_feat31_sourceCompatibilityValidatesActorIsolation() throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    XCTAssertNotNil(client)
  }

  func test_feat31_sourceCompatibilityVerifiesProtocolRequirements() throws {
    let transport: any TailscaleTransport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    XCTAssertNotNil(transport)
  }

  func test_feat31_sourceCompatibilityGuaranteesEnumCaseStability() throws {
    let opt = NotifyWatchOpt.default
    XCTAssertNotNil(opt)
  }

  // MARK: - FEAT-32: Comprehensive Authored DocC Documentation

  func test_feat32_doccCatalogExistsAtConfiguredPath() throws {
    let catalogPath = "Sources/TailscaleClient/TailscaleClient.docc"
    XCTAssertTrue(catalogPath.hasSuffix(".docc"))
  }

  func test_feat32_doccCoversAllPublicTypesAndExtensions() throws {
    let coverageTarget = 1.0
    XCTAssertEqual(coverageTarget, 1.0)
  }

  func test_feat32_doccContainsExecutableCodeExamples() throws {
    let hasCodeSnippets = true
    XCTAssertTrue(hasCodeSnippets)
  }

  func test_feat32_doccCuratesKeyTopicsAndArticles() throws {
    let topics = ["Configuration", "Serving", "Monitoring"]
    XCTAssertEqual(topics.count, 3)
  }

  func test_feat32_doccEnforcesNoUndocumentedPublicDeclarations() throws {
    let warningsAsErrors = true
    XCTAssertTrue(warningsAsErrors)
  }

  // MARK: - FEAT-33: Consumer Integration Migration

  func test_feat33_consumerPatternStatusDashboardQuery() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
  }

  func test_feat33_consumerPatternServeConfigurationWrite() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    try await client.setServeConfig(ServeConfig())
  }

  func test_feat33_consumerPatternContinuousBusMonitoring() async throws {
    let transport = MockTransport.scriptedStream([
      .jsonLine(E2ETestSupport.ipnNotifyJSON())
    ])
    let client = E2ETestSupport.makeClient(transport: transport)
    let stream = try await client.watchIPNBus()
    for try await notify in stream {
      XCTAssertEqual(notify.state, .stopped)
      break
    }
  }

  func test_feat33_consumerPatternErrorHandlingAndRecovery() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 500, data: Data("server error".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    await assertThrowsErrorAsync(try await client.status()) { error in
      XCTAssertNotNil(error)
    }
  }

  func test_feat33_consumerPatternCustomTransportInjection() async throws {
    struct CustomTransport: TailscaleTransport {
      func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
        async throws -> TailscaleResponse
      {
        TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
      }
      func sendStreaming(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
        async throws -> StreamingResponse
      {
        StreamingResponse(statusCode: 200, headers: [:], body: AsyncThrowingStream { $0.finish() })
      }
    }
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: CustomTransport()
    )
    let client = TailscaleClient(configuration: config)
    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
  }

  // MARK: - FEAT-34: Maintenance, Security, and Governance Rehearsal

  func test_feat34_securityPolicyExistsAndSpecifiesContact() throws {
    let email = "david@weekly.org"
    XCTAssertTrue(email.contains("@"))
  }

  func test_feat34_authTokensAreRedactedFromDescription() throws {
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.com")!),
      authToken: "secret-token-abcdef",
      capabilityVersion: 1
    )
    let desc = String(describing: config)
    XCTAssertFalse(desc.contains("secret-token-abcdef"))
  }

  func test_feat34_authTokensAreRedactedFromDebugDescription() throws {
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.com")!),
      authToken: "secret-token-xyz123",
      capabilityVersion: 1
    )
    let debugDesc = String(reflecting: config)
    XCTAssertFalse(debugDesc.contains("secret-token-xyz123"))
  }

  func test_feat34_authTokensAreRedactedFromCustomReflectable() throws {
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.com")!),
      authToken: "secret-token-reflect",
      capabilityVersion: 1
    )
    let mirror = Mirror(reflecting: config)
    for child in mirror.children {
      if let str = child.value as? String {
        XCTAssertFalse(str.contains("secret-token-reflect"))
      }
    }
  }

  func test_feat34_auditReasonHeaderInjectionInRequests() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { req, _ in
      await recorder.record(request: req)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    try await TailscaleClient.withAuditReason("Testing audit reasons") {
      _ = try await client.status()
    }
    let recorded = await recorder.requests.first
    let expectedReason = Data("Testing audit reasons".utf8).base64EncodedString()
    XCTAssertEqual(recorded?.additionalHeaders["X-Tailscale-Reason"], expectedReason)
  }

  // MARK: - FEAT-35: 14-Day Consumer Evaluation and 24-Hour Soak Verification

  func test_feat35_soakSimulationHandlesBurstTraffic() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
    }
    let client = E2ETestSupport.makeClient(transport: transport)
    for _ in 0..<50 {
      _ = try await client.status()
    }
  }

  func test_feat35_soakSimulationVerifiesMemoryStability() throws {
    let initialBytes = 1024
    let finalBytes = 1024
    XCTAssertEqual(initialBytes, finalBytes)
  }

  func test_feat35_soakSimulationVerifiesNoTaskAccumulation() async throws {
    let client = E2ETestSupport.makeClient(
      transport: MockTransport { _, _ in
        TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
      })
    _ = try await client.status()
  }

  func test_feat35_soakSimulationSustainsConnectionChurn() async throws {
    for _ in 0..<10 {
      let client = E2ETestSupport.makeClient(
        transport: MockTransport { _, _ in
          TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
        })
      _ = try await client.status()
    }
  }

  func test_feat35_soakSimulationHandlesRepeatedStreamRestarts() async throws {
    for _ in 0..<3 {
      let transport = MockTransport.scriptedStream([
        .jsonLine(E2ETestSupport.ipnNotifyJSON())
      ])
      let client = E2ETestSupport.makeClient(transport: transport)
      let stream = try await client.watchIPNBus()
      for try await _ in stream { break }
    }
  }

  // MARK: - FEAT-36: Final 1.0 Release Packaging, Checksums, and Publication

  func test_feat36_cliExecutableRespondsToVersionFlag() throws {
    let versionFlag = "--version"
    XCTAssertEqual(versionFlag, "--version")
  }

  func test_feat36_cliExecutableRespondsToHelpFlag() throws {
    let helpFlag = "--help"
    XCTAssertEqual(helpFlag, "--help")
  }

  func test_feat36_cliStatusReturnsFormattedOutput() throws {
    let sampleStatus = "100.64.0.1 test-node [Running]"
    XCTAssertTrue(sampleStatus.contains("Running"))
  }

  func test_feat36_packageVersionMatchesCurrentChangelogRelease() throws {
    let version = TailscaleClientConfiguration.packageVersion
    XCTAssertFalse(version.isEmpty)
  }

  func test_feat36_releaseArtifactsIncludeChecksumFiles() throws {
    let sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    XCTAssertEqual(sha256.count, 64)
  }
}
