// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class PingResultDecodingTests: XCTestCase {
  func testDecodesDirectPing() throws {
    let data = try fixture(named: "ping-sample", type: "json")
    let result = try JSONDecoder.tailscale().decode(PingResult.self, from: data)

    XCTAssertEqual(result.ip, "100.64.0.5")
    XCTAssertEqual(result.nodeIP, "100.64.0.5")
    XCTAssertEqual(result.nodeName, "example-peer")
    XCTAssertEqual(result.latencySeconds, 0.0234)
    XCTAssertEqual(result.endpoint, "203.0.113.50:41641")
    XCTAssertEqual(result.derpRegionID, 0)
    XCTAssertNil(result.error)

    // Verify computed properties
    XCTAssertTrue(result.isSuccess)
    XCTAssertTrue(result.isDirect)
    XCTAssertEqual(result.latencyDescription, "23.40 ms")
  }

  func testDecodesDerpPing() throws {
    let data = try fixture(named: "ping-derp-sample", type: "json")
    let result = try JSONDecoder.tailscale().decode(PingResult.self, from: data)

    XCTAssertEqual(result.ip, "100.64.0.6")
    XCTAssertEqual(result.nodeName, "remote-peer")
    XCTAssertEqual(result.latencySeconds, 0.0891)
    XCTAssertEqual(result.derpRegionID, 1)
    XCTAssertEqual(result.derpRegionCode, "sfo")
    XCTAssertNil(result.endpoint)

    // Verify computed properties
    XCTAssertTrue(result.isSuccess)
    XCTAssertFalse(result.isDirect)
    XCTAssertEqual(result.latencyDescription, "89.10 ms")
  }

  func testDecodesErrorPing() throws {
    let data = try fixture(named: "ping-error-sample", type: "json")
    let result = try JSONDecoder.tailscale().decode(PingResult.self, from: data)

    XCTAssertEqual(result.ip, "100.64.0.99")
    XCTAssertEqual(result.error, "timeout waiting for pong")
    XCTAssertNil(result.latencySeconds)

    // Verify computed properties
    XCTAssertFalse(result.isSuccess)
    XCTAssertNil(result.latencyDescription)
  }

  func testLatencyDescriptionFormats() throws {
    // Test microseconds format (< 1ms)
    let microJson = """
      {"IP": "100.64.0.1", "LatencySeconds": 0.000123}
      """
    let microResult = try JSONDecoder.tailscale().decode(
      PingResult.self, from: Data(microJson.utf8))
    XCTAssertEqual(microResult.latencyDescription, "123 µs")

    // Test milliseconds format (< 1s)
    let milliJson = """
      {"IP": "100.64.0.1", "LatencySeconds": 0.456}
      """
    let milliResult = try JSONDecoder.tailscale().decode(
      PingResult.self, from: Data(milliJson.utf8))
    XCTAssertEqual(milliResult.latencyDescription, "456.00 ms")

    // Test seconds format (>= 1s)
    let secJson = """
      {"IP": "100.64.0.1", "LatencySeconds": 2.5}
      """
    let secResult = try JSONDecoder.tailscale().decode(PingResult.self, from: Data(secJson.utf8))
    XCTAssertEqual(secResult.latencyDescription, "2.50 s")
  }

  func testIsDirectLogic() throws {
    // Direct: has endpoint, no DERP
    let directJson = """
      {"IP": "100.64.0.1", "Endpoint": "1.2.3.4:41641"}
      """
    let directResult = try JSONDecoder.tailscale().decode(
      PingResult.self, from: Data(directJson.utf8))
    XCTAssertTrue(directResult.isDirect)

    // Not direct: no endpoint
    let noEndpointJson = """
      {"IP": "100.64.0.1", "DERPRegionID": 1}
      """
    let noEndpointResult = try JSONDecoder.tailscale().decode(
      PingResult.self, from: Data(noEndpointJson.utf8))
    XCTAssertFalse(noEndpointResult.isDirect)

    // Not direct: has endpoint but also DERP
    let bothJson = """
      {"IP": "100.64.0.1", "Endpoint": "1.2.3.4:41641", "DERPRegionID": 1}
      """
    let bothResult = try JSONDecoder.tailscale().decode(PingResult.self, from: Data(bothJson.utf8))
    XCTAssertFalse(bothResult.isDirect)
  }
}
