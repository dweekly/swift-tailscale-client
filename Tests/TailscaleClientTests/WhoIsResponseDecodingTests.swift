// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class WhoIsResponseDecodingTests: XCTestCase {
  func testDecodesSampleWhoIs() throws {
    let data = try fixture(named: "whois-sample", type: "json")
    let response = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: data)

    // Verify top-level response
    XCTAssertNotNil(response.node)
    XCTAssertNotNil(response.userProfile)
    XCTAssertNotNil(response.capMap)

    // Verify node details
    let node = response.node!
    XCTAssertEqual(node.id, 1_234_567_890_123_456)
    XCTAssertEqual(node.stableID, "nStableExample123")
    XCTAssertEqual(node.name, "example-node.tail-example.ts.net.")
    XCTAssertEqual(node.user, 9_876_543_210_987_654)
    XCTAssertEqual(node.online, true)
    XCTAssertEqual(node.expired, false)
    XCTAssertEqual(node.isExitNode, false)
    XCTAssertEqual(node.tags, ["tag:server", "tag:production"])
    XCTAssertEqual(node.computedName, "example-macbook")

    // Verify addresses
    XCTAssertEqual(node.addresses.count, 2)
    XCTAssertTrue(node.addresses.contains("100.64.0.5/32"))

    // Verify endpoints
    XCTAssertEqual(node.endpoints.count, 2)
    XCTAssertTrue(node.endpoints.contains("203.0.113.50:41641"))

    // Verify hostinfo
    let hostinfo = node.hostinfo!
    XCTAssertEqual(hostinfo.os, "darwin")
    XCTAssertEqual(hostinfo.osVersion, "14.0.0")
    XCTAssertEqual(hostinfo.hostname, "example-macbook")
    XCTAssertEqual(hostinfo.deviceModel, "MacBookPro18,3")
    XCTAssertEqual(hostinfo.tailscaleVersion, "1.99.0")
    XCTAssertEqual(hostinfo.isSSHServer, true)

    // Verify user profile
    let profile = response.userProfile!
    XCTAssertEqual(profile.id, 9_876_543_210_987_654)
    XCTAssertEqual(profile.loginName, "admin@example.com")
    XCTAssertEqual(profile.displayName, "Admin User")

    // Verify dates are parsed
    XCTAssertNotNil(node.keyExpiry)
    XCTAssertNotNil(node.created)
    XCTAssertNotNil(node.lastSeen)
  }

  func testDecodesMinimalWhoIs() throws {
    let json = """
      {
        "Node": {
          "ID": 123,
          "Addresses": [],
          "AllowedIPs": [],
          "Endpoints": [],
          "Tags": []
        }
      }
      """
    let data = Data(json.utf8)
    let response = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: data)

    XCTAssertNotNil(response.node)
    XCTAssertEqual(response.node?.id, 123)
    XCTAssertNil(response.userProfile)
    XCTAssertNil(response.capMap)
  }
}
