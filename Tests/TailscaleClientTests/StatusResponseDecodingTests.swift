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
}
