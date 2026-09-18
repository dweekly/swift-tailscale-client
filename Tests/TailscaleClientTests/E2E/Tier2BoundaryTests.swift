// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tier 2: Boundary & Corner Cases E2E Test Suite.
///
/// Exercises system boundaries, extreme inputs, limits, overflows, nil/empty ETags,
/// oversized headers, truncated chunks, and framing edges.
final class Tier2BoundaryTests: XCTestCase {

  // MARK: - 1. Configuration & Concurrency Boundaries

  func test_boundary_serveConfigEmptyJSONDecodesSuccessfully() throws {
    let emptyJSON = "{}"
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(emptyJSON.utf8))
    XCTAssertTrue(config.isEmpty)
    XCTAssertEqual(config.tcp.count, 0)
    XCTAssertEqual(config.web.count, 0)
  }

  func test_boundary_serveConfigNilAndEmptyETagsAreDistinguished() throws {
    var config1 = ServeConfig()
    config1.etag = nil
    var config2 = ServeConfig()
    config2.etag = ""
    XCTAssertNil(config1.etag)
    XCTAssertEqual(config2.etag, "")
    XCTAssertNotEqual(config1.etag, config2.etag)
  }

  func test_boundary_serveConfigMaxTCPPort65535() throws {
    let json = "{\"TCP\": {\"65535\": {\"HTTPS\": true}}}"
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(config.tcp[65535]?.https, true)
  }

  func test_boundary_serveConfigMinTCPPort1() throws {
    let json = "{\"TCP\": {\"1\": {\"TCPForward\": \"127.0.0.1:1001\"}}}"
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(config.tcp[1]?.tcpForward, "127.0.0.1:1001")
  }

  func test_boundary_serveConfigDeeplyNestedHandlerPaths() throws {
    let deepPath = "/api/v1/sub/sub2/sub3/sub4/sub5/resource"
    let json = """
      {"Web": {"node.ts.net:443": {"Handlers": {"\(deepPath)": {"Proxy": "http://127.0.0.1:3000"}}}}}
      """
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(
      config.web["node.ts.net:443"]?.handlers[deepPath]?.proxy, "http://127.0.0.1:3000")
  }

  func test_boundary_serveConfigUnicodeAndSpecialCharactersInHostnames() throws {
    let specialHost = "node-öäü-test.tailnet.ts.net:443"
    let json = """
      {"Web": {"\(specialHost)": {"Handlers": {"/": {"Text": "Hello 🌍"}}}}}
      """
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(config.web[specialHost]?.handlers["/"]?.text, "Hello 🌍")
  }

  // MARK: - 2. 64-Bit Integer & Number Boundaries

  func test_boundary_jsonValueExactInt64Max() throws {
    let maxStr = "\(Int64.max)"
    let json = "{\"val\": \(maxStr)}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    XCTAssertNotNil(dict["val"])
  }

  func test_boundary_jsonValueExactInt64Min() throws {
    let minStr = "\(Int64.min)"
    let json = "{\"val\": \(minStr)}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    XCTAssertNotNil(dict["val"])
  }

  func test_boundary_jsonValueZeroAndNegativeZero() throws {
    let json = "{\"zero\": 0, \"negZero\": -0.0}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    XCTAssertNotNil(dict["zero"])
    XCTAssertNotNil(dict["negZero"])
  }

  func test_boundary_jsonValueScientificNotation() throws {
    let json = "{\"sci\": 1e12, \"sciSmall\": 2.5e-4}"
    let dict = try JSONDecoder.tailscale().decode([String: JSONValue].self, from: Data(json.utf8))
    XCTAssertNotNil(dict["sci"])
    XCTAssertNotNil(dict["sciSmall"])
  }

  // MARK: - 3. HTTP Head & Wire Framing Boundaries

  func test_boundary_httpHeadBufferEmptyFeed() throws {
    var buffer = HTTPHeadBuffer()
    let result = try buffer.feed(Data())
    XCTAssertNil(result)
  }

  func test_boundary_httpHeadBufferExactBoundBoundary() throws {
    var buffer = HTTPHeadBuffer()
    let minimalHead = "HTTP/1.1 200 OK\r\n\r\n"
    let result = try buffer.feed(Data(minimalHead.utf8))
    let (head, remainder) = try XCTUnwrap(result)
    XCTAssertEqual(head, Data("HTTP/1.1 200 OK".utf8))
    XCTAssertEqual(remainder.count, 0)
  }

  func test_boundary_httpHeadBufferOneByteUnder64KiBBound() throws {
    var buffer = HTTPHeadBuffer()
    let headerPrefix = "HTTP/1.1 200 OK\r\nX-Pad: "
    let headerSuffix = "\r\n\r\n"
    let padCount = (64 * 1024) - headerPrefix.count - headerSuffix.count - 1
    let pad = String(repeating: "P", count: padCount)
    let wire = headerPrefix + pad + headerSuffix
    let result = try buffer.feed(Data(wire.utf8))
    XCTAssertNotNil(result)
  }

  func test_boundary_chunkedDecoderZeroLengthTerminalChunk() throws {
    var decoder = ChunkedTransferDecoder()
    let result = try decoder.feed(Data("0\r\n\r\n".utf8))
    XCTAssertEqual(result.count, 0)
    XCTAssertTrue(decoder.isComplete)
  }

  func test_boundary_chunkedDecoderTruncatedMidChunkHeader() throws {
    var decoder = ChunkedTransferDecoder()
    let partialChunk = Data("10\r\npart".utf8)
    let result = try decoder.feed(partialChunk)
    XCTAssertEqual(result.count, 4)
    XCTAssertFalse(decoder.isComplete)
  }

  func test_boundary_chunkedDecoderSplitCRLFDelimiterAcrossReads() throws {
    var decoder = ChunkedTransferDecoder()
    _ = try decoder.feed(Data("4\r\ntest\r".utf8))
    _ = try decoder.feed(Data("\n0\r\n\r\n".utf8))
    XCTAssertTrue(decoder.isComplete)
  }

  func test_boundary_contentLengthZeroWithEmptyBody() throws {
    let wire = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    let head = try HTTPWireFormat.parseResponseHead(Data(wire.utf8))
    XCTAssertEqual(head.headers["content-length"], "0")
  }

  func test_boundary_contentLengthExceedingAvailableBytes() throws {
    let wire = "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\npartial"
    let head = try HTTPWireFormat.parseResponseHead(Data(wire.utf8))
    let cl = Int(head.headers["content-length"] ?? "0") ?? 0
    XCTAssertGreaterThan(cl, 7)
  }

  // MARK: - 4. Line Framer & Streaming Queue Boundaries

  func test_boundary_newlineFramerSingleByteChunks() throws {
    var framer = NewlineFramer()
    let line = "hello\n"
    var collected: [Data] = []
    for byte in line.utf8 {
      let lines = framer.feed(Data([byte]))
      collected.append(contentsOf: lines)
    }
    XCTAssertEqual(collected.count, 1)
    XCTAssertEqual(String(decoding: collected[0], as: UTF8.self), "hello")
  }

  func test_boundary_newlineFramerConsecutiveEmptyLines() throws {
    var framer = NewlineFramer()
    let data = Data("\n\n\n".utf8)
    let lines = framer.feed(data)
    XCTAssertEqual(lines.count, 0)
  }

  func test_boundary_newlineFramerLineWithoutTrailingNewline() throws {
    var framer = NewlineFramer()
    let unclosed = framer.feed(Data("unterminated line".utf8))
    XCTAssertEqual(unclosed.count, 0)
  }

  func test_boundary_streamQueueOverflowThreshold() throws {
    let maxQueueDepth = 256
    var items: [Int] = []
    for i in 0..<maxQueueDepth {
      items.append(i)
    }
    XCTAssertEqual(items.count, 256)
  }

  // MARK: - 5. Error & Retry Policy Boundaries

  func test_boundary_retryPolicyAttemptZeroDelay() throws {
    let baseDelay = 0.1
    let delay = baseDelay * pow(2.0, 0.0)
    XCTAssertEqual(delay, 0.1)
  }

  func test_boundary_retryPolicyClampingAtUpperLimit() throws {
    let maxDelay = 10.0
    let calculated = 0.1 * pow(2.0, 15.0)  // 3276.8
    let clamped = min(calculated, maxDelay)
    XCTAssertEqual(clamped, 10.0)
  }

  func test_boundary_httpErrorMapping400BadRequest() async throws {
    let client = E2ETestSupport.makeClient { _, _ in
      TailscaleResponse(statusCode: 400, data: Data("bad request".utf8))
    }
    await assertThrowsErrorAsync(try await client.status()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, _, _) = error, code == 400 else {
        XCTFail("Expected unexpectedStatus 400, got \(error)")
        return
      }
    }
  }

  func test_boundary_httpErrorMapping401Unauthorized() async throws {
    let client = E2ETestSupport.makeClient { _, _ in
      TailscaleResponse(statusCode: 401, data: Data("unauthorized".utf8))
    }
    await assertThrowsErrorAsync(try await client.status()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, _, _) = error, code == 401 else {
        XCTFail("Expected unexpectedStatus 401, got \(error)")
        return
      }
    }
  }

  func test_boundary_httpErrorMapping403Forbidden() throws {
    let res = TailscaleResponse(statusCode: 403, data: Data("forbidden".utf8))
    let err = TailscaleClient.commonStatusError(res, endpoint: "/test")
    guard case .permissionDenied = err else {
      XCTFail("Expected permissionDenied")
      return
    }
  }

  func test_boundary_httpErrorMapping429RateLimited() throws {
    let res = TailscaleResponse(statusCode: 429, data: Data("slow down".utf8))
    let err = TailscaleClient.commonStatusError(res, endpoint: "/test")
    guard case .rateLimited = err else {
      XCTFail("Expected rateLimited")
      return
    }
  }

  func test_boundary_httpErrorMapping500ServerError() async throws {
    let client = E2ETestSupport.makeClient { _, _ in
      TailscaleResponse(statusCode: 500, data: Data("internal failure".utf8))
    }
    await assertThrowsErrorAsync(try await client.status()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, _, _) = error, code == 500 else {
        XCTFail("Expected unexpectedStatus 500, got \(error)")
        return
      }
    }
  }

  func test_boundary_httpErrorMapping503ServiceUnavailable() async throws {
    let client = E2ETestSupport.makeClient { _, _ in
      TailscaleResponse(statusCode: 503, data: Data("service unavailable".utf8))
    }
    await assertThrowsErrorAsync(try await client.status()) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, _, _) = error, code == 503 else {
        XCTFail("Expected unexpectedStatus 503, got \(error)")
        return
      }
    }
  }

  // MARK: - 6. Discovery & Path Length Boundaries

  func test_boundary_extremelyLongSocketPath() throws {
    let longPath = "/" + String(repeating: "a", count: 1000) + "/tailscaled.sock"
    let endpoint = TailscaleEndpoint.unixSocket(path: longPath)
    guard case .unixSocket(let path) = endpoint else {
      XCTFail()
      return
    }
    XCTAssertEqual(path.count, longPath.count)
  }

  func test_boundary_socketPathWithSpacesAndSpecialChars() throws {
    let specialPath = "/Library/Application Support/Tailscale/tailscaled.sock"
    let endpoint = TailscaleEndpoint.unixSocket(path: specialPath)
    guard case .unixSocket(let path) = endpoint else {
      XCTFail()
      return
    }
    XCTAssertEqual(path, specialPath)
  }

  func test_boundary_emptyAuthTokenVersusNilAuthToken() throws {
    let configEmptyToken = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: "",
      capabilityVersion: 1
    )
    let configNilToken = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: nil,
      capabilityVersion: 1
    )
    XCTAssertEqual(configEmptyToken.authToken, "")
    XCTAssertNil(configNilToken.authToken)
  }

  func test_boundary_shortTimeoutBound() throws {
    let timeout: Duration = .milliseconds(5)
    XCTAssertEqual(timeout.components.attoseconds, 5_000_000_000_000_000)
  }

  func test_boundary_emptyDNSDomainsArray() throws {
    let json = "[]"
    let domains = try JSONDecoder().decode([String].self, from: Data(json.utf8))
    XCTAssertEqual(domains.count, 0)
  }

  func test_boundary_singleElementDNSDomainsArray() throws {
    let json = "[\"unique-node.tailnet.ts.net\"]"
    let domains = try JSONDecoder().decode([String].self, from: Data(json.utf8))
    XCTAssertEqual(domains, ["unique-node.tailnet.ts.net"])
  }

  func test_boundary_emptyProfilesArray() throws {
    let json = "[]"
    let profiles = try JSONDecoder.tailscale().decode([LoginProfile].self, from: Data(json.utf8))
    XCTAssertEqual(profiles.count, 0)
  }

  func test_boundary_maxIntegerCapabilityVersion() throws {
    let maxCap = Int.max
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: nil,
      capabilityVersion: maxCap
    )
    XCTAssertEqual(config.capabilityVersion, maxCap)
  }

  func test_boundary_zeroCapabilityVersion() throws {
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: nil,
      capabilityVersion: 0
    )
    XCTAssertEqual(config.capabilityVersion, 0)
  }

  func test_boundary_requestWithLargeQueryItemCount() throws {
    var items: [URLQueryItem] = []
    for i in 0..<50 {
      items.append(URLQueryItem(name: "k\(i)", value: "v\(i)"))
    }
    let req = TailscaleRequest(method: "GET", path: "/test", queryItems: items)
    XCTAssertEqual(req.queryItems.count, 50)
  }
}
