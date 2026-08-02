// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

/// Corner-case coverage for the pure HTTP wire-format types extracted from
/// the socket transport (see Documentation/TESTING.md checklist).
final class HTTPParsingTests: XCTestCase {

  // MARK: - ChunkedTransferDecoder

  private func decodeAll(_ fragments: [String]) throws -> (payload: Data, complete: Bool) {
    var decoder = ChunkedTransferDecoder()
    var payload = Data()
    for fragment in fragments {
      payload.append(try decoder.feed(Data(fragment.utf8)))
    }
    return (payload, decoder.isComplete)
  }

  func testChunkedSingleChunkInOneFeed() throws {
    let (payload, complete) = try decodeAll(["5\r\nhello\r\n0\r\n\r\n"])
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")
    XCTAssertTrue(complete)
  }

  func testChunkedMultipleChunks() throws {
    let (payload, complete) = try decodeAll(["5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"])
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello world")
    XCTAssertTrue(complete)
  }

  func testChunkedSizeLineSplitAcrossFeeds() throws {
    // "B" (hex 11) split from its CRLF, then payload split mid-way.
    let (payload, complete) = try decodeAll(["B", "\r", "\nhello", " world\r\n", "0\r\n\r\n"])
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello world")
    XCTAssertTrue(complete)
  }

  func testChunkedTerminatorSplitAcrossFeeds() throws {
    let (payload, complete) = try decodeAll(["5\r\nhello\r\n", "0", "\r\n", "\r", "\n"])
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")
    XCTAssertTrue(complete)
  }

  func testChunkedByteAtATime() throws {
    let wire = "3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n"
    let (payload, complete) = try decodeAll(wire.map(String.init))
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "abcdef")
    XCTAssertTrue(complete)
  }

  func testChunkedWithExtensions() throws {
    let (payload, complete) = try decodeAll(["5;name=value\r\nhello\r\n0\r\n\r\n"])
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")
    XCTAssertTrue(complete)
  }

  func testChunkedWithTrailers() throws {
    let (payload, complete) = try decodeAll([
      "5\r\nhello\r\n0\r\nX-Trailer: yes\r\nX-Other: also\r\n\r\n"
    ])
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")
    XCTAssertTrue(complete)
  }

  func testChunkedInvalidSizeThrows() {
    var decoder = ChunkedTransferDecoder()
    XCTAssertThrowsError(try decoder.feed(Data("zz\r\n".utf8))) { error in
      guard case TailscaleTransportError.malformedResponse = error else {
        return XCTFail("expected malformedResponse, got \(error)")
      }
    }
  }

  func testChunkedToleratesBareLF() throws {
    let (payload, complete) = try decodeAll(["5\nhello\n0\n\n"])
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")
    XCTAssertTrue(complete)
  }

  func testChunkedLargePayloadAcrossReads() throws {
    // Simulates a >1 MB NetMap line arriving in 4 KB reads.
    let big = String(repeating: "x", count: 1_200_000)
    let wire = "\(String(big.count, radix: 16))\r\n\(big)\r\n0\r\n\r\n"
    let wireData = Data(wire.utf8)
    var decoder = ChunkedTransferDecoder()
    var payload = Data()
    var index = wireData.startIndex
    while index < wireData.endIndex {
      let end = wireData.index(index, offsetBy: 4096, limitedBy: wireData.endIndex)
        ?? wireData.endIndex
      payload.append(try decoder.feed(Data(wireData[index..<end])))
      index = end
    }
    XCTAssertEqual(payload.count, big.count)
    XCTAssertTrue(decoder.isComplete)
  }

  func testChunkedIgnoresBytesAfterTerminalChunk() throws {
    var decoder = ChunkedTransferDecoder()
    let payload = try decoder.feed(Data("5\r\nhello\r\n0\r\n\r\nGARBAGE".utf8))
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")
    XCTAssertTrue(decoder.isComplete)
  }

  // MARK: - HTTPWireFormat.parseResponseHead

  func testParseHeadStatusAndHeaders() throws {
    let head = try HTTPWireFormat.parseResponseHead(
      Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Weird:  spaced  ".utf8))
    XCTAssertEqual(head.statusCode, 200)
    XCTAssertEqual(head.headers["content-type"], "application/json")
    XCTAssertEqual(head.headers["x-weird"], "spaced")
    XCTAssertFalse(head.isChunked)
  }

  func testParseHeadDetectsChunked() throws {
    let head = try HTTPWireFormat.parseResponseHead(
      Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked".utf8))
    XCTAssertTrue(head.isChunked)
  }

  func testParseHeadInvalidStatusLineThrows() {
    XCTAssertThrowsError(try HTTPWireFormat.parseResponseHead(Data("garbage".utf8)))
    XCTAssertThrowsError(try HTTPWireFormat.parseResponseHead(Data("HTTP/1.1 abc OK".utf8)))
    XCTAssertThrowsError(try HTTPWireFormat.parseResponseHead(Data()))
  }

  func testParseHeadSkipsMalformedHeaderLines() throws {
    let head = try HTTPWireFormat.parseResponseHead(
      Data("HTTP/1.1 204 No Content\r\nno-colon-here\r\nGood: yes".utf8))
    XCTAssertEqual(head.statusCode, 204)
    XCTAssertEqual(head.headers["good"], "yes")
    XCTAssertNil(head.headers["no-colon-here"])
  }

  // MARK: - HTTPWireFormat.requestData

  func testRequestDataShape() {
    let request = TailscaleRequest(
      method: "POST",
      path: "/localapi/v0/ping",
      queryItems: [URLQueryItem(name: "ip", value: "100.64.0.1")],
      body: Data("{}".utf8))
    let wire = String(
      decoding: HTTPWireFormat.requestData(for: request, capabilityVersion: 7, keepAlive: false),
      as: UTF8.self)

    XCTAssertTrue(wire.hasPrefix("POST /localapi/v0/ping?ip=100.64.0.1 HTTP/1.1\r\n"))
    XCTAssertTrue(wire.contains("Host: local-tailscaled.sock\r\n"))
    XCTAssertTrue(wire.contains("Connection: close\r\n"))
    XCTAssertTrue(wire.contains("Tailscale-Cap: 7\r\n"))
    XCTAssertTrue(wire.contains("Content-Length: 2\r\n"))
    XCTAssertTrue(wire.hasSuffix("\r\n\r\n{}"))
  }

  func testRequestDataKeepAliveAndNoBody() {
    let request = TailscaleRequest(path: "/localapi/v0/watch-ipn-bus")
    let wire = String(
      decoding: HTTPWireFormat.requestData(for: request, capabilityVersion: 1, keepAlive: true),
      as: UTF8.self)

    XCTAssertTrue(wire.hasPrefix("GET /localapi/v0/watch-ipn-bus HTTP/1.1\r\n"))
    XCTAssertTrue(wire.contains("Connection: keep-alive\r\n"))
    XCTAssertFalse(wire.contains("Content-Length"))
    XCTAssertTrue(wire.hasSuffix("\r\n\r\n"))
  }

  // MARK: - HTTPHeadBuffer

  func testHeadBufferSeparatorSplitAcrossFeeds() throws {
    var buffer = HTTPHeadBuffer()
    XCTAssertNil(try buffer.feed(Data("HTTP/1.1 200 OK\r\nA: b\r".utf8)))
    XCTAssertNil(try buffer.feed(Data("\n\r".utf8)))
    let result = try buffer.feed(Data("\n{\"body\":true}".utf8))
    let (head, remainder) = try XCTUnwrap(result)
    XCTAssertEqual(String(decoding: head, as: UTF8.self), "HTTP/1.1 200 OK\r\nA: b")
    XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "{\"body\":true}")
  }

  func testHeadBufferOversizedHeadThrows() {
    var buffer = HTTPHeadBuffer()
    let junk = Data(repeating: UInt8(ascii: "a"), count: HTTPHeadBuffer.maxHeadBytes + 1)
    XCTAssertThrowsError(try buffer.feed(junk))
  }

  // MARK: - NewlineFramer

  func testFramerSplitsLinesAcrossFeeds() {
    var framer = NewlineFramer()
    XCTAssertEqual(framer.feed(Data("{\"a\":1}\n{\"b\"".utf8)).count, 1)
    let lines = framer.feed(Data(":2}\n\n{\"c\":3}\n".utf8))
    XCTAssertEqual(lines.count, 2, "empty line must be dropped")
    XCTAssertEqual(String(decoding: lines[0], as: UTF8.self), "{\"b\":2}")
    XCTAssertEqual(String(decoding: lines[1], as: UTF8.self), "{\"c\":3}")
    XCTAssertNil(framer.flushRemainder())
  }

  func testFramerUTF8SplitAcrossFeeds() {
    var framer = NewlineFramer()
    let json = "{\"name\":\"héllo\"}"
    let bytes = Array(json.utf8)
    // Split inside the two-byte UTF-8 sequence for "é".
    let splitIndex = 9
    XCTAssertTrue(framer.feed(Data(bytes[..<splitIndex])).isEmpty)
    let lines = framer.feed(Data(bytes[splitIndex...] + [UInt8(ascii: "\n")]))
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(String(data: lines[0], encoding: .utf8), json)
  }

  func testFramerFlushRemainderAtEOF() {
    var framer = NewlineFramer()
    XCTAssertTrue(framer.feed(Data("partial".utf8)).isEmpty)
    XCTAssertEqual(
      framer.flushRemainder().map { String(decoding: $0, as: UTF8.self) }, "partial")
    XCTAssertNil(framer.flushRemainder())
  }
}
