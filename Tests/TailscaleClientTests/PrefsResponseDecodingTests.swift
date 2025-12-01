// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class PrefsResponseDecodingTests: XCTestCase {
  func testDecodesSamplePrefs() throws {
    let data = try fixture(named: "prefs-sample", type: "json")
    let prefs = try JSONDecoder.tailscale().decode(Prefs.self, from: data)

    // Verify basic prefs
    XCTAssertEqual(prefs.controlURL, "https://controlplane.tailscale.com")
    XCTAssertEqual(prefs.routeAll, false)
    XCTAssertEqual(prefs.exitNodeID, "nExitNodeStable123")
    XCTAssertEqual(prefs.exitNodeIP, "100.64.0.10")
    XCTAssertEqual(prefs.exitNodeAllowLANAccess, true)

    // Verify DNS and SSH settings
    XCTAssertEqual(prefs.corpDNS, true)
    XCTAssertEqual(prefs.runSSH, false)
    XCTAssertEqual(prefs.runWebClient, false)

    // Verify running state
    XCTAssertEqual(prefs.wantRunning, true)
    XCTAssertEqual(prefs.loggedOut, false)
    XCTAssertEqual(prefs.shieldsUp, false)

    // Verify tags and routes
    XCTAssertEqual(prefs.advertiseTags, ["tag:client"])
    XCTAssertEqual(prefs.advertiseRoutes, ["192.168.1.0/24", "10.0.0.0/8"])

    // Verify hostname and profile
    XCTAssertEqual(prefs.hostname, "my-device")
    XCTAssertEqual(prefs.profileName, "default")
    XCTAssertEqual(prefs.operatorUser, "admin")

    // Verify auto-update prefs
    XCTAssertNotNil(prefs.autoUpdate)
    XCTAssertEqual(prefs.autoUpdate?.check, true)
    XCTAssertEqual(prefs.autoUpdate?.apply, false)

    // Verify app connector
    XCTAssertNotNil(prefs.appConnector)
    XCTAssertEqual(prefs.appConnector?.advertise, false)

    // Verify other settings
    XCTAssertEqual(prefs.forceDaemon, false)
    XCTAssertEqual(prefs.noSNAT, false)
    XCTAssertEqual(prefs.netfilterMode, 2)
    XCTAssertEqual(prefs.postureChecking, false)
  }

  func testDecodesMinimalPrefs() throws {
    let json = "{}"
    let data = Data(json.utf8)
    let prefs = try JSONDecoder.tailscale().decode(Prefs.self, from: data)

    // All fields should be nil or empty arrays
    XCTAssertNil(prefs.controlURL)
    XCTAssertNil(prefs.routeAll)
    XCTAssertNil(prefs.exitNodeID)
    XCTAssertTrue(prefs.advertiseTags.isEmpty)
    XCTAssertTrue(prefs.advertiseRoutes.isEmpty)
  }
}
