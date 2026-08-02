// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class StatusResponseDecodingTests: XCTestCase {
  func testDecodesSampleStatus() throws {
    let data = try fixture(named: "status-sample", type: "json")
    let decoder = JSONDecoder.tailscale()
    let response = try decoder.decode(StatusResponse.self, from: data)

    XCTAssertEqual(response.version, "1.99.0-example")
    XCTAssertEqual(response.backendState, .running)
    XCTAssertEqual(
      response.tailscaleIPs, ["100.64.0.1", "fd7a:115c:a1e0:ab12:4843:cd96:6200:0001"])
    XCTAssertEqual(response.selfNode?.hostName, "example-device")
    XCTAssertEqual(response.peers.count, 1)
    XCTAssertNotNil(response.users["1234567890123456"])
    XCTAssertEqual(response.clientVersion?.runningLatest, true)
  }

  /// Tailscale 1.98.9 sends CapMap values that are arrays of JSON objects
  /// (e.g. "default-auto-update"); these must decode as .unsupported rather
  /// than failing the whole status response.
  func testDecodesNodeWithObjectCapabilityValues() throws {
    let json = """
      {
        "ID": "n1",
        "PublicKey": "nodekey:abc",
        "HostName": "example",
        "DNSName": "example.tail.ts.net.",
        "CapMap": {
          "default-auto-update": [{"Apply": true}],
          "https://tailscale.com/cap/is-admin": null,
          "example-ints": [1, 2],
          "example-strings": ["a"],
          "example-mixed": [true, 3.5]
        }
      }
      """
    let node = try JSONDecoder.tailscale().decode(NodeStatus.self, from: Data(json.utf8))

    guard case .unsupported = node.capabilityMap?["default-auto-update"] else {
      return XCTFail("expected .unsupported for object payload")
    }
    guard case .null = node.capabilityMap?["https://tailscale.com/cap/is-admin"] else {
      return XCTFail("expected .null")
    }
    guard case .integers([1, 2]) = node.capabilityMap?["example-ints"] else {
      return XCTFail("expected .integers")
    }
    guard case .strings(["a"]) = node.capabilityMap?["example-strings"] else {
      return XCTFail("expected .strings")
    }
    guard case .unsupported = node.capabilityMap?["example-mixed"] else {
      return XCTFail("expected .unsupported for mixed array")
    }
  }
}
