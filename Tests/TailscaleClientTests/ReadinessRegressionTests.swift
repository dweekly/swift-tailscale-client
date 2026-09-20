// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

/// Reproducible regression tests documenting the pre-1.0 readiness review findings
/// detailed in Documentation/PLAN-1.0.md (Milestone 0 / W0).
///
/// These tests capture the exact edge cases and data-loss/framing defenses
/// implemented across W1 and W2 hardening:
/// 1. Unknown ServeConfig fields (root and nested) are preserved across decode/re-encode.
/// 2. HTTPHeadBuffer rejects heads > 64 KiB even when the `\r\n\r\n` delimiter is present.
/// 3. Chunked transfer decoding in unary transport requires `isComplete`.
/// 4. Content-Length header is validated against body byte count in unary responses.
final class ReadinessRegressionTests: XCTestCase {

  // MARK: - Finding 1: ServeConfig Unknown Fields Loss (Defended in W1 / PR 02)

  /// Verifies that unmodeled JSON fields in ServeConfig at both the root level
  /// and inside nested structures (TCPPortHandler, WebServerConfig, HTTPHandler)
  /// are losslessly preserved across the decode -> edit one known field -> re-encode lifecycle,
  /// with complete 64-bit integer precision.
  func testServeConfigPreservesUnknownRootAndNestedFields() throws {
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
                "UnknownHandlerField": 99999,
                "Large64BitInt": 18446744073709551615
              }
            },
            "UnknownWebSetting": true
          }
        },
        "UnknownRootField": "preserve-me-root",
        "ExperimentalDaemonFlags": [1, 2, 3],
        "ExplicitNullField": null
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

    // Unmodeled fields present on decoded model
    XCTAssertEqual(decoded._unmodeledFields["UnknownRootField"], .string("preserve-me-root"))
    XCTAssertEqual(
      decoded._unmodeledFields["ExperimentalDaemonFlags"],
      .array([.integer(1), .integer(2), .integer(3)])
    )
    XCTAssertEqual(decoded._unmodeledFields["ExplicitNullField"], .null)
    XCTAssertEqual(
      decoded.tcp[443]?._unmodeledFields["UnknownTCPSetting"], .string("preserve-me-tcp"))
    XCTAssertEqual(
      decoded.web["node.tail1234.ts.net:443"]?._unmodeledFields["UnknownWebSetting"], .bool(true))
    XCTAssertEqual(
      decoded.web["node.tail1234.ts.net:443"]?.handlers["/"]?._unmodeledFields[
        "UnknownHandlerField"],
      .integer(99999)
    )
    XCTAssertEqual(
      decoded.web["node.tail1234.ts.net:443"]?.handlers["/"]?._unmodeledFields["Large64BitInt"],
      .unsignedInteger(18_446_744_073_709_551_615)
    )

    // Edit a known field
    var modified = decoded
    modified.web["node.tail1234.ts.net:443"]?.handlers["/"]?.proxy = "http://127.0.0.1:4000"

    // Re-encode to JSON
    let encodedData = try JSONEncoder().encode(modified)
    let reencodedObject =
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
      )

    // DEFENSE VERIFICATION:
    // Root-level unknown fields are preserved
    XCTAssertEqual(reencodedObject["UnknownRootField"] as? String, "preserve-me-root")
    XCTAssertEqual(reencodedObject["ExperimentalDaemonFlags"] as? [Int], [1, 2, 3])
    XCTAssertTrue(reencodedObject.keys.contains("ExplicitNullField"))
    XCTAssertTrue(reencodedObject["ExplicitNullField"] is NSNull)

    // Nested TCP unknown fields are preserved
    let tcpDict = reencodedObject["TCP"] as? [String: Any]
    let port443Dict = tcpDict?["443"] as? [String: Any]
    XCTAssertEqual(port443Dict?["UnknownTCPSetting"] as? String, "preserve-me-tcp")

    // Nested Web unknown fields are preserved
    let webDict = reencodedObject["Web"] as? [String: Any]
    let siteDict = webDict?["node.tail1234.ts.net:443"] as? [String: Any]
    XCTAssertEqual(siteDict?["UnknownWebSetting"] as? Bool, true)

    // Nested Handler unknown fields are preserved
    let handlersDict = siteDict?["Handlers"] as? [String: Any]
    let rootHandlerDict = handlersDict?["/"] as? [String: Any]
    XCTAssertEqual(rootHandlerDict?["UnknownHandlerField"] as? Int, 99999)
    XCTAssertEqual(rootHandlerDict?["Proxy"] as? String, "http://127.0.0.1:4000")

    // Re-decode from encoded JSON and assert equality
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encodedData)
    XCTAssertEqual(redecoded, modified)
  }

  // MARK: - Finding 2: HTTPHeadBuffer Header Size Limit Enforcement (Defended in W2 / PR 04)

  /// Verifies that `HTTPHeadBuffer` rejects HTTP heads exceeding `maxHeadBytes` (64 KiB),
  /// even when the `\r\n\r\n` delimiter is present in the feed buffer.
  func testHTTPHeadBufferRejectsOver64KiBWhenDelimiterIsPresent() throws {
    var buffer = HTTPHeadBuffer()

    // Construct a header block exceeding maxHeadBytes (64 KiB = 65,536 bytes)
    // with the `\r\n\r\n` terminator included.
    let oversizedValue = String(repeating: "A", count: 70 * 1024)
    let wire = "HTTP/1.1 200 OK\r\nX-Oversized: \(oversizedValue)\r\n\r\n{\"status\":\"ok\"}"
    let wireData = Data(wire.utf8)

    // DEFENSE VERIFICATION:
    // Feeding an oversized head now throws `TailscaleTransportError.malformedResponse`
    // despite `\r\n\r\n` being present.
    XCTAssertThrowsError(try buffer.feed(wireData)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("HTTP head exceeds"),
        "Expected error detail to mention head size limit, got: '\(detail)'"
      )
    }
  }

  // MARK: - Finding 3: Chunked Transfer Decoder Completion Check (Defended in W2 / PR 04)

  /// Verifies that unary response body decoding rejects truncated chunked streams
  /// where `decoder.isComplete` is false (e.g. terminal 0-chunk missing upon EOF).
  func testChunkedTransferDecoderRejectsTruncatedStreamWithoutCompletionCheck() throws {
    var decoder = ChunkedTransferDecoder()

    // Truncated chunked payload: 5 bytes ("hello"), followed by EOF without "0\r\n\r\n"
    let truncatedWire = Data("5\r\nhello\r\n".utf8)
    let payload = try decoder.feed(truncatedWire)

    // Raw decoder yields the partial payload but leaves isComplete == false
    XCTAssertEqual(String(decoding: payload, as: UTF8.self), "hello")
    XCTAssertFalse(decoder.isComplete)

    // DEFENSE VERIFICATION:
    // Response body decoding for chunked transfers enforces decoder.isComplete,
    // rejecting incomplete chunked bodies with typed malformedResponse error.
    let head = HTTPWireFormat.ResponseHead(
      statusCode: 200,
      headers: ["transfer-encoding": "chunked"]
    )
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(truncatedWire, head: head)) {
      error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertEqual(detail, "Incomplete chunked transfer")
    }
  }

  // MARK: - Finding 4: Content-Length Validation in Unary Responses (Defended in W2 / PR 04)

  /// Verifies that unary response body decoding validates received byte count against
  /// the `Content-Length` header, rejecting truncated bodies with typed malformedResponse error.
  func testContentLengthParsedHeaderIsValidatedAgainstBodyLength() throws {
    let headWire = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8)
    let head = try HTTPWireFormat.parseResponseHead(headWire)

    XCTAssertEqual(head.headers["content-length"], "100")

    // If only 10 bytes arrive before socket close:
    let partialBody = Data("1234567890".utf8)

    // DEFENSE VERIFICATION:
    // Response body decoding validates body byte count against Content-Length,
    // throwing malformedResponse when truncated.
    XCTAssertThrowsError(try HTTPWireFormat.decodeResponseBody(partialBody, head: head)) { error in
      guard case TailscaleTransportError.malformedResponse(let detail) = error else {
        return XCTFail("Expected malformedResponse, got \(error)")
      }
      XCTAssertEqual(detail, "Truncated Content-Length body")
    }

    // Matching body length succeeds:
    let fullBody = Data(repeating: UInt8(ascii: "x"), count: 100)
    let decoded = try HTTPWireFormat.decodeResponseBody(fullBody, head: head)
    XCTAssertEqual(decoded.count, 100)
  }
}
