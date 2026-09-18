// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

/// Empirical adversarial test harness challenging:
/// 1. HTTPHeadBuffer split point invariance (1-byte, 2-byte, 15-byte, intra-delimiter splits)
/// 2. HTTPHeadBuffer 64 KiB boundary enforcement (65,536 accepted, 65,537 rejected with/without delimiter)
/// 3. Content-Length body framing validation (truncated 1000->999, excess 100->101, negative/overflow lengths)
/// 4. ChunkedTransferDecoder completion & fault tolerance (mid-chunk truncation, missing terminal chunk, size line > 1024)
/// 5. Real-socket fault server integration verifying typed transport errors over Unix sockets
final class AdversarialWireFramingChallengerTests: XCTestCase {

  // MARK: - 1. HTTPHeadBuffer Split-Point Invariance

  func testHTTPHeadBufferFedOneByteAtATime() throws {
    let rawResponse =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTailscale-Version: 1.76.0\r\n\r\n{\"key\":\"value\"}"
    let wire = Data(rawResponse.utf8)
    let expectedHead =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTailscale-Version: 1.76.0"
    let expectedRemainder = "{\"key\":\"value\"}"

    var buffer = HTTPHeadBuffer()
    var result: (head: Data, bodyRemainder: Data)? = nil
    var bytesFed = 0

    for byte in wire {
      bytesFed += 1
      if let r = try buffer.feed(Data([byte])) {
        result = r
        break
      }
    }

    let unwrapped = try XCTUnwrap(result, "Feed must succeed upon reaching delimiter")
    let head = unwrapped.head
    var remainder = unwrapped.bodyRemainder
    remainder.append(wire.suffix(wire.count - bytesFed))

    XCTAssertEqual(String(decoding: head, as: UTF8.self), expectedHead)
    XCTAssertEqual(String(decoding: remainder, as: UTF8.self), expectedRemainder)
  }

  func testHTTPHeadBufferFedTwoBytesAtATime() throws {
    let rawResponse = "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nHello World!"
    let wire = Data(rawResponse.utf8)
    let expectedHead = "HTTP/1.1 200 OK\r\nContent-Length: 12"
    let expectedRemainder = "Hello World!"

    var buffer = HTTPHeadBuffer()
    var result: (head: Data, bodyRemainder: Data)? = nil
    var bytesFed = 0
    let chunkSize = 2

    for start in stride(from: 0, to: wire.count, by: chunkSize) {
      let chunk = wire.subdata(in: start..<min(start + chunkSize, wire.count))
      bytesFed += chunk.count
      if let r = try buffer.feed(chunk) {
        result = r
        break
      }
    }

    let unwrapped = try XCTUnwrap(result, "Feed must succeed upon delimiter")
    let head = unwrapped.head
    var remainder = unwrapped.bodyRemainder
    remainder.append(wire.suffix(wire.count - bytesFed))

    XCTAssertEqual(String(decoding: head, as: UTF8.self), expectedHead)
    XCTAssertEqual(String(decoding: remainder, as: UTF8.self), expectedRemainder)
  }

  func testHTTPHeadBufferFedFifteenBytesAtATime() throws {
    let rawResponse =
      "HTTP/1.1 200 OK\r\nServer: tailscaled\r\nContent-Length: 17\r\n\r\n{\"status\":\"ready\"}"
    let wire = Data(rawResponse.utf8)
    let expectedHead = "HTTP/1.1 200 OK\r\nServer: tailscaled\r\nContent-Length: 17"
    let expectedRemainder = "{\"status\":\"ready\"}"

    var buffer = HTTPHeadBuffer()
    var result: (head: Data, bodyRemainder: Data)? = nil
    var bytesFed = 0
    let chunkSize = 15

    for start in stride(from: 0, to: wire.count, by: chunkSize) {
      let chunk = wire.subdata(in: start..<min(start + chunkSize, wire.count))
      bytesFed += chunk.count
      if let r = try buffer.feed(chunk) {
        result = r
        break
      }
    }

    let unwrapped = try XCTUnwrap(result, "Feed must succeed upon delimiter")
    let head = unwrapped.head
    var remainder = unwrapped.bodyRemainder
    remainder.append(wire.suffix(wire.count - bytesFed))

    XCTAssertEqual(String(decoding: head, as: UTF8.self), expectedHead)
    XCTAssertEqual(String(decoding: remainder, as: UTF8.self), expectedRemainder)
  }

  func testHTTPHeadBufferSplitDirectlyInsideDelimiter() throws {
    let headData = Data("HTTP/1.1 200 OK\r\nContent-Length: 4".utf8)
    let bodyData = Data("ping".utf8)
    let delimiterData = Data("\r\n\r\n".utf8)

    // Test every possible byte split inside the 4-byte delimiter "\r\n\r\n":
    // Split 1: [0x0D] | [0x0A, 0x0D, 0x0A]
    // Split 2: [0x0D, 0x0A] | [0x0D, 0x0A]
    // Split 3: [0x0D, 0x0A, 0x0D] | [0x0A]
    for splitAt in 1...3 {
      var buffer = HTTPHeadBuffer()
      let delimPart1 = delimiterData.prefix(splitAt)
      let delimPart2 = delimiterData.suffix(4 - splitAt)

      let feed1 = headData + delimPart1
      let feed2 = delimPart2 + bodyData

      let res1 = try buffer.feed(feed1)
      XCTAssertNil(res1, "Partial delimiter must not trigger completion (splitAt: \(splitAt))")

      let res2 = try XCTUnwrap(
        try buffer.feed(feed2), "Second feed must complete (splitAt: \(splitAt))")
      XCTAssertEqual(res2.head, headData)
      XCTAssertEqual(res2.bodyRemainder, bodyData)
    }
  }

  func testHTTPHeadBufferExhaustiveSplitPointsAcrossHeadAndBody() throws {
    let rawResponse =
      "HTTP/1.1 200 OK\r\nDate: Thu, 17 Sep 2026 22:00:00 GMT\r\nContent-Length: 10\r\n\r\n0123456789"
    let wire = Data(rawResponse.utf8)
    let expectedHead =
      "HTTP/1.1 200 OK\r\nDate: Thu, 17 Sep 2026 22:00:00 GMT\r\nContent-Length: 10"
    let expectedRemainder = "0123456789"

    for splitIndex in 0...wire.count {
      var buffer = HTTPHeadBuffer()
      let chunk1 = wire.prefix(splitIndex)
      let chunk2 = wire.suffix(wire.count - splitIndex)

      let head: Data
      let remainder: Data

      if let res = try buffer.feed(chunk1) {
        head = res.head
        remainder = res.bodyRemainder + chunk2
      } else {
        let res = try XCTUnwrap(try buffer.feed(chunk2), "Failed at split index \(splitIndex)")
        head = res.head
        remainder = res.bodyRemainder
      }

      XCTAssertEqual(
        String(decoding: head, as: UTF8.self), expectedHead, "Head mismatch at \(splitIndex)")
      XCTAssertEqual(
        String(decoding: remainder, as: UTF8.self), expectedRemainder,
        "Remainder mismatch at \(splitIndex)")
    }
  }

  // MARK: - 2. HTTPHeadBuffer 64 KiB Limits & Boundary Stress

  func testHTTPHeadBufferExactly65536BytesAccepted() throws {
    var buffer = HTTPHeadBuffer()
    let prefix = "HTTP/1.1 200 OK\r\nX-Padding: "
    let target = 64 * 1024  // exactly 65,536 bytes
    let padCount = target - prefix.utf8.count
    let head = prefix + String(repeating: "Z", count: padCount)
    let wire = head + "\r\n\r\nTrailerBody"

    let result = try XCTUnwrap(try buffer.feed(Data(wire.utf8)))
    XCTAssertEqual(result.head.count, 65536)
    XCTAssertEqual(String(decoding: result.bodyRemainder, as: UTF8.self), "TrailerBody")
  }

  func testHTTPHeadBuffer65537BytesWithDelimiterThrowsMalformedResponse() {
    var buffer = HTTPHeadBuffer()
    let prefix = "HTTP/1.1 200 OK\r\nX-Padding: "
    let target = (64 * 1024) + 1  // 65,537 bytes
    let padCount = target - prefix.utf8.count
    let head = prefix + String(repeating: "Z", count: padCount)
    let wire = head + "\r\n\r\nBody"

    XCTAssertThrowsError(try buffer.feed(Data(wire.utf8))) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertTrue(
        detail.contains("HTTP head exceeds 65536 bytes"), "Unexpected detail: \(detail)")
    }
  }

  func testHTTPHeadBuffer65536BytesWithoutDelimiterReturnsNil() throws {
    var buffer = HTTPHeadBuffer()
    let raw = Data(repeating: UInt8(ascii: "A"), count: 64 * 1024)
    let res = try buffer.feed(raw)
    XCTAssertNil(
      res, "Buffer at exactly 64 KiB without delimiter must return nil waiting for delimiter")
  }

  func testHTTPHeadBuffer65537BytesWithoutDelimiterThrowsMalformedResponse() {
    var buffer = HTTPHeadBuffer()
    let raw = Data(repeating: UInt8(ascii: "A"), count: (64 * 1024) + 1)
    XCTAssertThrowsError(try buffer.feed(raw)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertTrue(detail.contains("HTTP head exceeds 65536 bytes"))
    }
  }

  func testHTTPHeadBuffer65537BytesAcrossIncrementalFeedsThrows() throws {
    var buffer = HTTPHeadBuffer()
    let chunk1 = Data(repeating: UInt8(ascii: "B"), count: 64 * 1024)
    let res = try buffer.feed(chunk1)
    XCTAssertNil(res)

    let chunk2 = Data([UInt8(ascii: "X")])
    XCTAssertThrowsError(try buffer.feed(chunk2)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertTrue(detail.contains("HTTP head exceeds 65536 bytes"))
    }
  }

  func testHTTPHeadBufferSmallHeadFollowedByMassiveBodyInSingleFeed() throws {
    var buffer = HTTPHeadBuffer()
    let head = "HTTP/1.1 200 OK\r\nContent-Length: 262144\r\n\r\n"
    let body = Data(repeating: 0x42, count: 256 * 1024)  // 256 KiB body
    let wire = Data(head.utf8) + body

    let result = try XCTUnwrap(try buffer.feed(wire))
    XCTAssertEqual(
      String(decoding: result.head, as: UTF8.self), "HTTP/1.1 200 OK\r\nContent-Length: 262144")
    XCTAssertEqual(result.bodyRemainder.count, 256 * 1024)
  }

  // MARK: - 3. Content-Length Body Framing Validation

  func testContentLengthTruncatedBodyThrows() {
    let head = HTTPWireFormat.ResponseHead(statusCode: 200, headers: ["content-length": "1000"])
    let partialBody = Data(repeating: UInt8(ascii: "A"), count: 999)  // 999 bytes, declared 1000

    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(partialBody, head: head)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertEqual(detail, "Truncated Content-Length body")
    }
  }

  func testContentLengthExcessBodyThrows() {
    let head = HTTPWireFormat.ResponseHead(statusCode: 200, headers: ["content-length": "100"])
    let excessBody = Data(repeating: UInt8(ascii: "B"), count: 101)  // 101 bytes, declared 100

    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(excessBody, head: head)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertEqual(detail, "Truncated Content-Length body")
    }
  }

  func testContentLengthZeroExactMatch() throws {
    let head = HTTPWireFormat.ResponseHead(statusCode: 204, headers: ["content-length": "0"])
    let decoded = try HTTPWireFormat.decodeResponseBody(Data(), head: head)
    XCTAssertEqual(decoded.count, 0)
  }

  func testContentLengthZeroWithExcessBytesThrows() {
    let head = HTTPWireFormat.ResponseHead(statusCode: 204, headers: ["content-length": "0"])
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(Data([0x01]), head: head)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertEqual(detail, "Truncated Content-Length body")
    }
  }

  func testContentLengthNegativeValueThrows() {
    let head = HTTPWireFormat.ResponseHead(statusCode: 200, headers: ["content-length": "-1"])
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(Data("test".utf8), head: head)) {
      error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertTrue(detail.contains("Invalid Content-Length header: '-1'"))
    }
  }

  func testContentLengthNonNumericValueThrows() {
    let head = HTTPWireFormat.ResponseHead(statusCode: 200, headers: ["content-length": "1000xyz"])
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(Data("test".utf8), head: head)) {
      error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertTrue(detail.contains("Invalid Content-Length header"))
    }
  }

  func testContentLengthOverflowValueThrows() {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: [
        "content-length": "99999999999999999999999999999999999999999999999999999999999999999"
      ]
    )
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(Data("test".utf8), head: head)) {
      error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertTrue(detail.contains("Invalid Content-Length header"))
    }
  }

  // MARK: - 4. Chunked Transfer Decoder Completion & Fault Invariance

  func testChunkedDecoderTruncatedMidChunkThrowsInUnary() throws {
    // Declares 10 hex (16 bytes), sends only 6 bytes, then ends
    let truncatedWire = Data("10\r\n123456".utf8)
    var decoder = ChunkedTransferDecoder()
    let partial = try decoder.feed(truncatedWire)
    XCTAssertEqual(String(decoding: partial, as: UTF8.self), "123456")
    XCTAssertFalse(decoder.isComplete)

    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200, headers: ["transfer-encoding": "chunked"])
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(truncatedWire, head: head)) {
      error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertEqual(detail, "Incomplete chunked transfer")
    }
  }

  func testChunkedDecoderMissingTerminalChunkThrowsInUnary() throws {
    // Valid first chunk, but stream ends before terminal 0-chunk
    let wire = Data("5\r\nhello\r\n".utf8)
    var decoder = ChunkedTransferDecoder()
    let decoded = try decoder.feed(wire)
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "hello")
    XCTAssertFalse(decoder.isComplete)

    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200, headers: ["transfer-encoding": "chunked"])
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(wire, head: head)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertEqual(detail, "Incomplete chunked transfer")
    }
  }

  func testChunkedDecoderMissingTrailerBlankLineThrowsInUnary() throws {
    // Terminal 0-chunk present without the trailing CRLF blank line
    let wire = Data("5\r\nhello\r\n0\r\n".utf8)
    var decoder = ChunkedTransferDecoder()
    _ = try decoder.feed(wire)
    XCTAssertFalse(decoder.isComplete, "Must not be complete until terminal blank line is consumed")

    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200, headers: ["transfer-encoding": "chunked"])
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(wire, head: head)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertEqual(detail, "Incomplete chunked transfer")
    }
  }

  func testChunkedDecoderSizeLineExceeding1024BytesThrows() {
    var decoder = ChunkedTransferDecoder()
    // 1025 bytes without newline
    let excessiveLine = Data(repeating: UInt8(ascii: "0"), count: 1025)
    XCTAssertThrowsError(try decoder.feed(excessiveLine)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertEqual(detail, "Chunk size line too long")
    }
  }

  func testChunkedDecoderTrailerLineExceeding1024BytesThrows() throws {
    var decoder = ChunkedTransferDecoder()
    // Terminal 0-chunk followed by an oversized trailer header line
    let terminal0 = Data("0\r\n".utf8)
    _ = try decoder.feed(terminal0)

    let excessiveTrailer = Data(repeating: UInt8(ascii: "T"), count: 1025)
    XCTAssertThrowsError(try decoder.feed(excessiveTrailer)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertEqual(detail, "Chunk trailer line too long")
    }
  }

  func testChunkedDecoderInvalidHexChunkSizeThrows() {
    var decoder = ChunkedTransferDecoder()
    let badHex = Data("zz\r\n".utf8)
    XCTAssertThrowsError(try decoder.feed(badHex)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got: \(error)")
      }
      XCTAssertTrue(detail.contains("Invalid chunk size line: 'zz'"))
    }
  }

  func testChunkedDecoderWithChunkExtensionsDecodesSuccessfully() throws {
    let wire = Data("5;name=extension;other=123\r\nhello\r\n0;terminal=true\r\n\r\n".utf8)
    var decoder = ChunkedTransferDecoder()
    let decoded = try decoder.feed(wire)
    XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "hello")
    XCTAssertTrue(decoder.isComplete)
  }

  func testChunkedDecoderFedOneByteAtATimeCompletes() throws {
    let wire = Data("4\r\nWiki\r\n5\r\npedia\r\ne\r\n in \r\n\r\nchunks\r\n0\r\n\r\n".utf8)
    let expected = "Wikipedia in \r\n\r\nchunks"
    var decoder = ChunkedTransferDecoder()
    var result = Data()

    for byte in wire {
      let decoded = try decoder.feed(Data([byte]))
      result.append(decoded)
    }

    XCTAssertTrue(decoder.isComplete)
    XCTAssertEqual(String(decoding: result, as: UTF8.self), expected)
  }

  func testChunkedEncodingOverridesContentLengthHeader() throws {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: [
        "transfer-encoding": "chunked",
        "content-length": "42",  // Contradictory Content-Length must be ignored
      ]
    )
    let wire = Data("5\r\nhello\r\n0\r\n\r\n".utf8)
    let body = try HTTPWireFormat.decodeResponseBody(wire, head: head)
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
  }

  // MARK: - 5. Real-Socket Fault Server Integration

  #if canImport(Darwin) || os(Linux)
    func testRealSocketTruncatedContentLengthThrowsMalformedResponse() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\nshort",
          closeAfterWrite: true)
      ])
      defer { server.stop() }

      let config = TailscaleClientConfiguration(
        endpoint: .unixSocket(path: server.path),
        authToken: nil,
        capabilityVersion: 1,
        requestTimeout: .seconds(2),
        transport: URLSessionTailscaleTransport()
      )
      let client = TailscaleClient(configuration: config)

      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          return XCTFail("Expected .transport(.malformedResponse), got: \(error)")
        }
        XCTAssertEqual(detail, "Truncated Content-Length body")
      }
    }

    func testRealSocketExcessContentLengthThrowsMalformedResponse() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nexcessive-data",
          closeAfterWrite: true)
      ])
      defer { server.stop() }

      let config = TailscaleClientConfiguration(
        endpoint: .unixSocket(path: server.path),
        authToken: nil,
        capabilityVersion: 1,
        requestTimeout: .seconds(2),
        transport: URLSessionTailscaleTransport()
      )
      let client = TailscaleClient(configuration: config)

      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          return XCTFail("Expected .transport(.malformedResponse), got: \(error)")
        }
        XCTAssertEqual(detail, "Truncated Content-Length body")
      }
    }

    func testRealSocketIncompleteChunkedStreamThrowsMalformedResponse() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\ntest\r\n",
          closeAfterWrite: true)
      ])
      defer { server.stop() }

      let config = TailscaleClientConfiguration(
        endpoint: .unixSocket(path: server.path),
        authToken: nil,
        capabilityVersion: 1,
        requestTimeout: .seconds(2),
        transport: URLSessionTailscaleTransport()
      )
      let client = TailscaleClient(configuration: config)

      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          return XCTFail("Expected .transport(.malformedResponse), got: \(error)")
        }
        XCTAssertEqual(detail, "Incomplete chunked transfer")
      }
    }

    func testRealSocketOversizedChunkSizeLineThrowsMalformedResponse() async throws {
      let excessiveLine = String(repeating: "0", count: 1025)
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(excessiveLine)",
          closeAfterWrite: true)
      ])
      defer { server.stop() }

      let config = TailscaleClientConfiguration(
        endpoint: .unixSocket(path: server.path),
        authToken: nil,
        capabilityVersion: 1,
        requestTimeout: .seconds(2),
        transport: URLSessionTailscaleTransport()
      )
      let client = TailscaleClient(configuration: config)

      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          return XCTFail("Expected .transport(.malformedResponse), got: \(error)")
        }
        XCTAssertEqual(detail, "Chunk size line too long")
      }
    }

    func testRealSocketOversizedHeaderThrowsMalformedResponse() async throws {
      let oversizedHeader = String(repeating: "H", count: 66 * 1024)
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nX-Oversized: \(oversizedHeader)\r\n\r\n{}", closeAfterWrite: true)
      ])
      defer { server.stop() }

      let config = TailscaleClientConfiguration(
        endpoint: .unixSocket(path: server.path),
        authToken: nil,
        capabilityVersion: 1,
        requestTimeout: .seconds(2),
        transport: URLSessionTailscaleTransport()
      )
      let client = TailscaleClient(configuration: config)

      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          return XCTFail("Expected .transport(.malformedResponse), got: \(error)")
        }
        XCTAssertTrue(detail.contains("HTTP head exceeds"))
      }
    }
    func testHTTPHeadBuffer65535BytesAccepted() throws {
      var buffer = HTTPHeadBuffer()
      let prefix = "HTTP/1.1 200 OK\r\nX-Pad: "
      let target = (64 * 1024) - 1  // 65,535 bytes
      let padCount = target - prefix.utf8.count
      let head = prefix + String(repeating: "M", count: padCount)
      let wire = head + "\r\n\r\nOK"

      let result = try XCTUnwrap(try buffer.feed(Data(wire.utf8)))
      XCTAssertEqual(result.head.count, 65535)
      XCTAssertEqual(String(decoding: result.bodyRemainder, as: UTF8.self), "OK")
    }

    func testHTTPHeadBufferInterleavedWithEmptyDataFeeds() throws {
      var buffer = HTTPHeadBuffer()
      let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
      let data = Data(raw.utf8)

      XCTAssertNil(try buffer.feed(Data()))
      XCTAssertNil(try buffer.feed(data.prefix(10)))
      XCTAssertNil(try buffer.feed(Data()))
      XCTAssertNil(try buffer.feed(Data()))

      let res = try XCTUnwrap(try buffer.feed(data.suffix(data.count - 10)))
      XCTAssertEqual(
        String(decoding: res.head, as: UTF8.self), "HTTP/1.1 200 OK\r\nContent-Length: 2")
      XCTAssertEqual(String(decoding: res.bodyRemainder, as: UTF8.self), "{}")
    }

    func testFuzzRandomizedSplitFeedsAgainstHTTPHeadBuffer() throws {
      // Run 50 iterations with pseudo-random seed
      for i in 0..<50 {
        let headerCount = (i % 8) + 1
        var headerLines = ["HTTP/1.1 200 OK"]
        for h in 0..<headerCount {
          headerLines.append("X-Custom-Header-\(h): value-\(i)-\(h)")
        }
        let headString = headerLines.joined(separator: "\r\n")
        let bodyLength = (i * 17) % 500
        let bodyData = Data((0..<bodyLength).map { UInt8($0 % 255) })
        let wire = Data(headString.utf8) + Data("\r\n\r\n".utf8) + bodyData

        var buffer = HTTPHeadBuffer()
        var offset = 0
        var result: (head: Data, bodyRemainder: Data)? = nil
        var remainderAccumulator = Data()

        while offset < wire.count {
          // Pseudo-random chunk size between 1 and 37
          let step = ((offset * 31 + i * 17 + 7) % 37) + 1
          let end = min(offset + step, wire.count)
          let slice = wire.subdata(in: offset..<end)
          offset = end

          if result == nil {
            if let r = try buffer.feed(slice) {
              result = r
              remainderAccumulator.append(r.bodyRemainder)
            }
          } else {
            remainderAccumulator.append(slice)
          }
        }

        let res = try XCTUnwrap(result, "Fuzz iteration \(i) must find delimiter")
        XCTAssertEqual(
          String(decoding: res.head, as: UTF8.self), headString, "Fuzz iteration \(i) head mismatch"
        )
        XCTAssertEqual(
          remainderAccumulator, bodyData, "Fuzz iteration \(i) body remainder mismatch")
      }
    }

    func testFuzzRandomizedChunkedTransferDecoder() throws {
      for i in 0..<50 {
        let numChunks = (i % 6) + 1
        var fullPayload = Data()
        var wireData = Data()

        for c in 0..<numChunks {
          let chunkLen = ((c * 43 + i * 13) % 250) + 1
          let chunkBytes = Data((0..<chunkLen).map { UInt8(($0 + c) % 255) })
          fullPayload.append(chunkBytes)

          let hexSize = String(chunkLen, radix: 16)
          let ext = (c % 2 == 0) ? ";ext=val\(c)" : ""
          wireData.append(Data("\(hexSize)\(ext)\r\n".utf8))
          wireData.append(chunkBytes)
          wireData.append(Data("\r\n".utf8))
        }
        // Terminal 0-chunk
        wireData.append(Data("0\r\n\r\n".utf8))

        var decoder = ChunkedTransferDecoder()
        var decodedAccumulator = Data()
        var offset = 0

        while offset < wireData.count {
          let step = ((offset * 19 + i * 29 + 3) % 23) + 1
          let end = min(offset + step, wireData.count)
          let slice = wireData.subdata(in: offset..<end)
          offset = end

          let decoded = try decoder.feed(slice)
          decodedAccumulator.append(decoded)
        }

        XCTAssertTrue(decoder.isComplete, "Fuzz iteration \(i) must be complete")
        XCTAssertEqual(decodedAccumulator, fullPayload, "Fuzz iteration \(i) payload mismatch")
      }
    }
  #endif
}
