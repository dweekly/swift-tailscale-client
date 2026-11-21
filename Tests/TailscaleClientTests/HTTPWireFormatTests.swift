// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

final class HTTPWireFormatTests: XCTestCase {

  // MARK: - HTTPHeadBuffer Split Point Invariance

  /// Tests that splitting a representative HTTP head + body at EVERY possible byte index
  /// yields identical parsed head and body remainder results.
  func testHTTPHeadBufferEverySplitPoint() throws {
    let rawResponse =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}"
    let wire = Data(rawResponse.utf8)
    let expectedHead = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15"
    let expectedRemainder = "{\"status\":\"ok\"}"

    for splitIndex in 0...wire.count {
      var buffer = HTTPHeadBuffer()
      let chunk1 = wire.prefix(splitIndex)
      let chunk2 = wire.suffix(wire.count - splitIndex)

      var result: (head: Data, bodyRemainder: Data)?
      result = try buffer.feed(chunk1)
      var head: Data
      var remainder: Data
      if let r = result {
        head = r.head
        remainder = r.bodyRemainder + chunk2
      } else {
        let r = try XCTUnwrap(try buffer.feed(chunk2), "Failed at split index \(splitIndex)")
        head = r.head
        remainder = r.bodyRemainder
      }

      XCTAssertEqual(
        String(decoding: head, as: UTF8.self),
        expectedHead,
        "Head mismatch at split index \(splitIndex)"
      )
      XCTAssertEqual(
        String(decoding: remainder, as: UTF8.self),
        expectedRemainder,
        "Remainder mismatch at split index \(splitIndex)"
      )
    }
  }

  // MARK: - HTTPHeadBuffer 64 KiB Limits

  func testHTTPHeadBufferExactly64KiBHeadAccepted() throws {
    var buffer = HTTPHeadBuffer()
    let prefix = "HTTP/1.1 200 OK\r\nX-Pad: "
    let targetHeadBytes = HTTPHeadBuffer.maxHeadBytes  // 65,536 bytes
    let padCount = targetHeadBytes - prefix.utf8.count
    let headStr = prefix + String(repeating: "P", count: padCount)
    let wire = headStr + "\r\n\r\nRemainder"

    let (head, remainder) = try XCTUnwrap(try buffer.feed(Data(wire.utf8)))
    XCTAssertEqual(head.count, targetHeadBytes)
    XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "Remainder")
  }

  func testHTTPHeadBuffer64KiBPlusOneByteWithDelimiterRejects() {
    var buffer = HTTPHeadBuffer()
    let prefix = "HTTP/1.1 200 OK\r\nX-Pad: "
    let targetHeadBytes = HTTPHeadBuffer.maxHeadBytes + 1
    let padCount = targetHeadBytes - prefix.utf8.count
    let headStr = prefix + String(repeating: "P", count: padCount)
    let wire = headStr + "\r\n\r\n{}"

    XCTAssertThrowsError(try buffer.feed(Data(wire.utf8))) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertTrue(detail.contains("HTTP head exceeds"))
    }
  }

  func testHTTPHeadBufferLargeBodyWithSmallHeadSucceeds() throws {
    var buffer = HTTPHeadBuffer()
    let headStr = "HTTP/1.1 200 OK\r\nContent-Length: 131072\r\n\r\n"
    let body = Data(repeating: UInt8(ascii: "B"), count: 128 * 1024)
    let wire = Data(headStr.utf8) + body

    let (head, remainder) = try XCTUnwrap(try buffer.feed(wire))
    XCTAssertEqual(
      String(decoding: head, as: UTF8.self), "HTTP/1.1 200 OK\r\nContent-Length: 131072")
    XCTAssertEqual(remainder.count, 128 * 1024)
  }

  // MARK: - ChunkedTransferDecoder Split Points

  /// Tests that splitting a multi-chunk payload at EVERY possible byte index
  /// decodes the identical payload with isComplete == true.
  func testChunkedDecoderEverySplitPoint() throws {
    let wire = Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
    let expected = "hello world"

    for splitIndex in 0...wire.count {
      var decoder = ChunkedTransferDecoder()
      let chunk1 = wire.prefix(splitIndex)
      let chunk2 = wire.suffix(wire.count - splitIndex)

      var decoded = try decoder.feed(chunk1)
      decoded.append(try decoder.feed(chunk2))

      XCTAssertEqual(
        String(decoding: decoded, as: UTF8.self),
        expected,
        "Mismatch at split index \(splitIndex)"
      )
      XCTAssertTrue(decoder.isComplete, "Not complete at split index \(splitIndex)")
    }
  }

  // MARK: - Streaming body framing

  /// Splits a Content-Length-framed streaming response (head, body, then
  /// bytes that belong to no response) at every byte index and runs it
  /// through the same head buffer, body decoder, and line framer the Unix
  /// socket streaming path uses: the lines and the completion point must not
  /// depend on where the reads split.
  func testContentLengthStreamingBodyEverySplitPoint() throws {
    let body = "{\"Version\":\"t1\"}\n{\"Version\":\"t2\"}"
    let wire = Data(
      ("HTTP/1.1 400 Bad Request\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        + "\nEXTRA\n").utf8)

    for splitIndex in 0...wire.count {
      var headBuffer = HTTPHeadBuffer()
      var decoder: ResponseBodyDecoder?
      var framer = NewlineFramer()
      var lines: [String] = []
      for piece in [wire.prefix(splitIndex), wire.suffix(wire.count - splitIndex)] {
        var bodyBytes = Data(piece)
        if decoder == nil {
          guard let (head, remainder) = try headBuffer.feed(piece) else { continue }
          let parsed = try HTTPWireFormat.parseResponseHead(head)
          decoder = ResponseBodyDecoder(framing: try parsed.bodyFraming())
          bodyBytes = remainder
        }
        for line in try framer.feed(try decoder!.feed(bodyBytes)) {
          lines.append(String(decoding: line, as: UTF8.self))
        }
      }
      let finished = try XCTUnwrap(decoder, "No head at split index \(splitIndex)")
      XCTAssertTrue(finished.isComplete, "Not complete at split index \(splitIndex)")
      if let remainder = try framer.flushRemainder() {
        lines.append(String(decoding: remainder, as: UTF8.self))
      }
      XCTAssertEqual(
        lines, ["{\"Version\":\"t1\"}", "{\"Version\":\"t2\"}"],
        "Mismatch at split index \(splitIndex)")
    }
  }

  func testBodyFramingFollowsMessageLengthRules() throws {
    func framing(_ status: Int, _ headers: [String: String]) throws -> HTTPWireFormat.BodyFraming {
      try HTTPWireFormat.ResponseHead(statusCode: status, headers: headers).bodyFraming()
    }
    XCTAssertEqual(try framing(400, ["content-length": "68"]), .contentLength(68))
    XCTAssertEqual(try framing(500, ["content-length": "0"]), .contentLength(0))
    XCTAssertEqual(try framing(200, ["transfer-encoding": "chunked"]), .chunked)
    XCTAssertEqual(
      try framing(200, ["transfer-encoding": "chunked", "content-length": "5"]), .chunked)
    XCTAssertEqual(try framing(200, [:]), .untilClose)
    XCTAssertEqual(try framing(204, [:]), .contentLength(0))
    XCTAssertEqual(try framing(304, ["content-length": "10"]), .contentLength(0))
    XCTAssertThrowsError(try framing(400, ["content-length": "abc"]))
    XCTAssertThrowsError(try framing(400, ["content-length": "-1"]))
  }

  func testResponseBodyDecoderReportsShortBodyAtEOF() throws {
    var decoder = ResponseBodyDecoder(framing: .contentLength(10))
    XCTAssertEqual(try decoder.feed(Data("12345".utf8)), Data("12345".utf8))
    XCTAssertFalse(decoder.isComplete)
    XCTAssertThrowsError(try decoder.finishAtEOF()) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertEqual(detail, "Truncated Content-Length body")
    }
    var untilClose = ResponseBodyDecoder(framing: .untilClose)
    XCTAssertEqual(try untilClose.feed(Data("abc".utf8)), Data("abc".utf8))
    XCTAssertFalse(untilClose.isComplete)
    XCTAssertNoThrow(try untilClose.finishAtEOF())
  }

  // MARK: - HTTPWireFormat.decodeResponseBody

  func testDecodeResponseBodyMatchingContentLength() throws {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: ["content-length": "5"]
    )
    let body = try HTTPWireFormat.decodeResponseBody(Data("hello".utf8), head: head)
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
  }

  func testDecodeResponseBodyTruncatedContentLengthThrows() {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: ["content-length": "100"]
    )
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(Data("short".utf8), head: head)) {
      error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertEqual(detail, "Truncated Content-Length body")
    }
  }

  func testDecodeResponseBodyExceededContentLengthThrows() {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: ["content-length": "5"]
    )
    XCTAssertThrowsError(
      try HTTPWireFormat.decodeResponseBody(Data("longer-than-5".utf8), head: head)
    ) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertEqual(detail, "Truncated Content-Length body")
    }
  }

  func testDecodeResponseBodyInvalidContentLengthHeaderThrows() {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: ["content-length": "not-an-int"]
    )
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(Data("hello".utf8), head: head)) {
      error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertTrue(detail.contains("Invalid Content-Length header"))
    }
  }

  func testDecodeResponseBodyCompleteChunked() throws {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: ["transfer-encoding": "chunked"]
    )
    let rawChunked = Data("5\r\nhello\r\n0\r\n\r\n".utf8)
    let body = try HTTPWireFormat.decodeResponseBody(rawChunked, head: head)
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
  }

  func testDecodeResponseBodyIncompleteChunkedThrows() {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: ["transfer-encoding": "chunked"]
    )
    let rawChunked = Data("5\r\nhello\r\n".utf8)
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(rawChunked, head: head)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertEqual(detail, "Incomplete chunked transfer")
    }
  }

  func testDecodeResponseBodyChunkedOverridesContentLength() throws {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: [
        "transfer-encoding": "chunked",
        "content-length": "999",
      ]
    )
    let rawChunked = Data("5\r\nhello\r\n0\r\n\r\n".utf8)
    let body = try HTTPWireFormat.decodeResponseBody(rawChunked, head: head)
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
  }

  func testDecodeResponseBodyNoFramingHeadersPassesBody() throws {
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: ["content-type": "application/json"]
    )
    let rawBody = Data("{\"unframed\":true}".utf8)
    let body = try HTTPWireFormat.decodeResponseBody(rawBody, head: head)
    XCTAssertEqual(body, rawBody)
  }
}
