// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

/// Reproducible regression tests documenting the pre-1.0 readiness review findings
/// detailed in Documentation/PLAN-1.0.md (Milestone 0 / W0).
///
/// These tests capture the exact edge cases and data-loss/framing vulnerabilities
/// present prior to W1 and W2 hardening:
/// 1. Unknown ServeConfig fields (root and nested) are dropped upon decode/re-encode.
/// 2. HTTPHeadBuffer allows heads > 64 KiB when the `\r\n\r\n` delimiter is present.
/// 3. Chunked transfer decoding in unary transport does not require `isComplete`.
/// 4. Content-Length header is not validated against body byte count in unary responses.
final class ReadinessRegressionTests: XCTestCase {

  // MARK: - Finding 1: ServeConfig Unknown Fields Loss

  /// Demonstrates that unmodeled JSON fields in ServeConfig at both the root level
  /// and inside nested structures (TCPPortHandler, WebServerConfig, HTTPHandler)
  /// are permanently lost when decoded into `ServeConfig` and re-encoded.
  ///
  /// W1 will replace this with recursive lossless preservation.
  func testServeConfigCurrentlyDropsUnknownRootAndNestedFields() throws {
    let rawJSON = """
      {
        "TCP": {
          "443": {
            "HTTPS": true,
            "UnknownTCPSetting": "preserve-me-tcp"
          }
        },
        "Web": {
          "node.tail1234.ts.net:443": {
            "Handlers": {
              "/": {
                "Proxy": "http://127.0.0.1:3000",
                "UnknownHandlerField": 99999
              }
            },
            "UnknownWebSetting": true
          }
        },
        "UnknownRootField": "preserve-me-root",
        "ExperimentalDaemonFlags": [1, 2, 3]
      }
      """

    let inputData = Data(rawJSON.utf8)
    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: inputData)

    // Known fields decoded successfully
    XCTAssertEqual(decoded.tcp[443]?.https, true)
    XCTAssertEqual(
      decoded.web["node.tail1234.ts.net:443"]?.handlers["/"]?.proxy,
      "http://127.0.0.1:3000"
    )

    // Re-encode to JSON
    let encodedData = try JSONEncoder().encode(decoded)
    let reencodedObject =
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
      )

    // REPRODUCED BEHAVIOR:
    // Root-level unknown fields are completely absent
    XCTAssertNil(
      reencodedObject["UnknownRootField"],
      "Vulnerability reproduction: UnknownRootField is lost on re-encoding"
    )
    XCTAssertNil(
      reencodedObject["ExperimentalDaemonFlags"],
      "Vulnerability reproduction: ExperimentalDaemonFlags is lost on re-encoding"
    )

    // Nested TCP unknown fields are absent
    let tcpDict = reencodedObject["TCP"] as? [String: Any]
    let port443Dict = tcpDict?["443"] as? [String: Any]
    XCTAssertNil(
      port443Dict?["UnknownTCPSetting"],
      "Vulnerability reproduction: nested TCP unknown fields are lost on re-encoding"
    )

    // Nested Web unknown fields are absent
    let webDict = reencodedObject["Web"] as? [String: Any]
    let siteDict = webDict?["node.tail1234.ts.net:443"] as? [String: Any]
    XCTAssertNil(
      siteDict?["UnknownWebSetting"],
      "Vulnerability reproduction: nested Web unknown fields are lost on re-encoding"
    )

    // Nested Handler unknown fields are absent
    let handlersDict = siteDict?["Handlers"] as? [String: Any]
    let rootHandlerDict = handlersDict?["/"] as? [String: Any]
    XCTAssertNil(
      rootHandlerDict?["UnknownHandlerField"],
      "Vulnerability reproduction: nested Handler unknown fields are lost on re-encoding"
    )
  }

  // MARK: - Finding 2: HTTPHeadBuffer Header Size Limit Bypass

  /// Demonstrates that `HTTPHeadBuffer` only checks `maxHeadBytes` (64 KiB)
  /// when `\r\n\r\n` has NOT yet been found in the accumulated buffer.
  /// If an oversized header block arrives with the delimiter already present,
  /// `HTTPHeadBuffer` returns the oversized head without throwing.
  ///
  /// W2 will enforce the header limit even when the delimiter is present.
  func testHTTPHeadBufferAcceptsOver64KiBWhenDelimiterIsPresent() throws {
    var buffer = HTTPHeadBuffer()

    // Construct a header block exceeding maxHeadBytes (64 KiB = 65,536 bytes)
    // with the `\r\n\r\n` terminator included.
    let oversizedValue = String(repeating: "A", count: 70 * 1024)
    let wire = "HTTP/1.1 200 OK\r\nX-Oversized: \(oversizedValue)\r\n\r\n{\"status\":\"ok\"}"
    let wireData = Data(wire.utf8)

    // Feeding this directly succeeds instead of throwing!
    let result = try buffer.feed(wireData)
    let (headData, remainderData) = try XCTUnwrap(result)

    // REPRODUCED BEHAVIOR:
    // Head exceeds 64 KiB (maxHeadBytes) but was accepted anyway
    XCTAssertGreaterThan(
      headData.count,
      HTTPHeadBuffer.maxHeadBytes,
      "Vulnerability reproduction: HTTPHeadBuffer accepted head > 64 KiB because \\r\\n\\r\\n was present"
    )
    XCTAssertEqual(String(decoding: remainderData, as: UTF8.self), "{\"status\":\"ok\"}")
  }

  // MARK: - Finding 3: Chunked Transfer Decoder Completion Check

  /// Demonstrates that feeding truncated chunked data into `ChunkedTransferDecoder`
  /// returns whatever chunk data was parsed without throwing, while leaving
  /// `isComplete == false`. In `UnixSocketTransport.performSend`, this result was
  /// returned directly as the response body without checking `isComplete`,
  /// meaning a truncated chunked response (e.g. socket closed early) would be
  /// silently accepted as a valid complete response.
  ///
  /// W2 will require `decoder.isComplete` before completing unary responses.
  func testChunkedTransferDecoderAllowsTruncatedStreamWithoutCompletionCheck() throws {
    var decoder = ChunkedTransferDecoder()

    // Truncated chunked payload: 5 bytes ("hello"), followed by EOF without "0\r\n\r\n"
    let truncatedWire = Data("5\r\nhello\r\n".utf8)
    let payload = try decoder.feed(truncatedWire)

    // Payload was yielded without error
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")

    // REPRODUCED BEHAVIOR:
    // The decoder is NOT complete, but no error was thrown.
    // In UnixSocketTransport.performSend:
    //   if head.isChunked {
    //     var decoder = ChunkedTransferDecoder()
    //     bodyData = try decoder.feed(body)
    //   }
    // `isComplete` is never inspected, so truncated chunks are returned as valid responses!
    XCTAssertFalse(
      decoder.isComplete,
      "Vulnerability reproduction: decoder is incomplete, but unary path does not check isComplete"
    )
  }

  // MARK: - Finding 4: Content-Length Validation in Unary Responses

  /// Demonstrates that `HTTPWireFormat.parseResponseHead` parses the Content-Length
  /// header into the dictionary, but UnixSocketTransport.performSend does not validate
  /// that the received body byte count matches `Content-Length`.
  ///
  /// W2 will enforce Content-Length validation on unary responses.
  func testContentLengthParsedHeaderIsNotValidatedAgainstBodyLength() throws {
    let headWire = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8)
    let head = try HTTPWireFormat.parseResponseHead(headWire)

    XCTAssertEqual(head.headers["content-length"], "100")

    // If only 10 bytes arrive before socket close:
    let partialBody = Data("1234567890".utf8)

    // REPRODUCED BEHAVIOR:
    // In current UnixSocketTransport.performSend:
    //   return TailscaleResponse(statusCode: head.statusCode, data: bodyData, headers: head.headers)
    // partialBody.count (10) != 100, yet TailscaleResponse is constructed without error.
    XCTAssertNotEqual(
      partialBody.count,
      Int(head.headers["content-length"]!)!,
      "Vulnerability reproduction: body length does not match Content-Length header"
    )
  }
}
