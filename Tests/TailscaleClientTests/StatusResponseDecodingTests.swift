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

    let capMap = try XCTUnwrap(response.selfNode?.capabilityMap)
    guard case .integers([86400]) = capMap["tailnet.maxKeyDuration"] else {
      return XCTFail("expected .integers([86400])")
    }
    guard case .booleans([false]) = capMap["default-auto-update"] else {
      return XCTFail("expected .booleans([false])")
    }
    guard case .null = capMap["https://tailscale.com/cap/ssh"] else {
      return XCTFail("expected .null")
    }
    guard case .strings(["example.com"]) = capMap["tailnet-display-name"] else {
      return XCTFail("expected .strings")
    }
    guard case .raw(let values) = capMap["example.com/cap/structured"],
      case .object(let object) = values.first,
      object["mode"] == .string("strict"),
      object["retries"] == .integer(3)
    else {
      return XCTFail("expected .raw with one object")
    }
  }

  func testCapabilityValueDecodesArbitraryJSON() throws {
    let json = """
      {
        "empty": [],
        "mixed": [1, "two", true],
        "nested": [[1, 2], [3]],
        "doubles": [1.5, 2.5]
      }
      """
    let decoded = try JSONDecoder().decode(
      [String: CapabilityValue].self, from: Data(json.utf8))

    guard case .integers([]) = decoded["empty"] else {
      return XCTFail("expected empty array to decode as .integers([])")
    }
    guard case .raw([.integer(1), .string("two"), .bool(true)]) = decoded["mixed"] else {
      return XCTFail("expected .raw for mixed array")
    }
    guard
      case .raw([.array([.integer(1), .integer(2)]), .array([.integer(3)])]) = decoded["nested"]
    else {
      return XCTFail("expected .raw for nested arrays")
    }
    guard case .raw([.double(1.5), .double(2.5)]) = decoded["doubles"] else {
      return XCTFail("expected .raw for doubles")
    }
  }

  func testCapabilityValueRejectsNonArrayScalar() {
    // Upstream CapMap values are always null or a JSON array; a bare scalar
    // indicates a malformed response and should surface as a decoding error.
    XCTAssertThrowsError(
      try JSONDecoder().decode([String: CapabilityValue].self, from: Data(#"{"cap": 5}"#.utf8)))
  }

  /// Live daemons send CapMap values beyond int/string arrays (booleans,
  /// objects, mixed arrays); these must decode losslessly as .raw rather
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

    guard case .raw(let values) = node.capabilityMap?["default-auto-update"],
      case .object(let object) = values.first,
      object["Apply"] == .bool(true)
    else {
      return XCTFail("expected .raw with one object for object payload")
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
    guard case .raw([.bool(true), .double(3.5)]) = node.capabilityMap?["example-mixed"] else {
      return XCTFail("expected .raw for mixed array")
    }
  }
}
