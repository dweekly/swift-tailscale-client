// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class DERPMapDecodingTests: XCTestCase {

  func testDecodesFixture() throws {
    let data = try fixture(named: "derpmap-sample", type: "json")
    let map = try JSONDecoder.tailscale().decode(DERPMap.self, from: data)

    XCTAssertEqual(map.regions.count, 3)
    XCTAssertTrue(map.omitDefaultRegions)
    XCTAssertEqual(map.homeParams?.regionScore[1], 0.95)
    XCTAssertEqual(map.homeParams?.regionScore[10], 1.05)

    let nyc = try XCTUnwrap(map.regions[1])
    XCTAssertEqual(nyc.regionCode, "nyc")
    XCTAssertEqual(nyc.regionName, "New York City")
    XCTAssertEqual(nyc.latitude ?? 0, 40.712775, accuracy: 0.0001)
    XCTAssertFalse(nyc.avoid)
    XCTAssertEqual(nyc.nodes.count, 2)

    let node = try XCTUnwrap(nyc.nodes.first)
    XCTAssertEqual(node.name, "1f")
    XCTAssertEqual(node.hostName, "derp1f.tailscale.com")
    XCTAssertEqual(node.ipv4, "104.248.1.160")
    XCTAssertTrue(node.canPort80)
    XCTAssertFalse(node.stunOnly)
  }

  func testSortedRegionsOrdersByID() throws {
    let data = try fixture(named: "derpmap-sample", type: "json")
    let map = try JSONDecoder.tailscale().decode(DERPMap.self, from: data)
    XCTAssertEqual(map.sortedRegions.map(\.regionID), [1, 2, 900])
  }

  func testRegionFlagsAndCustomPorts() throws {
    let data = try fixture(named: "derpmap-sample", type: "json")
    let map = try JSONDecoder.tailscale().decode(DERPMap.self, from: data)

    let custom = try XCTUnwrap(map.regions[900])
    XCTAssertTrue(custom.avoid)
    XCTAssertTrue(custom.noMeasureNoHome)

    let pinned = try XCTUnwrap(custom.nodes.first)
    XCTAssertEqual(pinned.certName, "derp-cert.example.com")
    XCTAssertEqual(pinned.effectiveSTUNPort, 3479)
    XCTAssertEqual(pinned.effectiveDERPPort, 8443)

    let stunless = try XCTUnwrap(custom.nodes.last)
    XCTAssertNil(stunless.effectiveSTUNPort)
    XCTAssertEqual(stunless.effectiveDERPPort, 443)
  }

  func testDefaultPortConventions() {
    let node = DERPNode(name: "x", regionID: 1, hostName: "derp.example.com")
    XCTAssertEqual(node.effectiveSTUNPort, 3478)
    XCTAssertEqual(node.effectiveDERPPort, 443)
  }

  func testDecodesMinimalMap() throws {
    let json = Data(#"{"Regions": null}"#.utf8)
    let map = try JSONDecoder.tailscale().decode(DERPMap.self, from: json)
    XCTAssertTrue(map.regions.isEmpty)
    XCTAssertNil(map.homeParams)
    XCTAssertFalse(map.omitDefaultRegions)
  }

  func testRoundTripsThroughCodable() throws {
    let data = try fixture(named: "derpmap-sample", type: "json")
    let map = try JSONDecoder.tailscale().decode(DERPMap.self, from: data)
    let reencoded = try JSONEncoder().encode(map)
    let decodedAgain = try JSONDecoder.tailscale().decode(DERPMap.self, from: reencoded)
    XCTAssertEqual(map, decodedAgain)
  }
}

final class ExitNodeSuggestionDecodingTests: XCTestCase {

  func testDecodesFixture() throws {
    let data = try fixture(named: "suggest-exit-node-sample", type: "json")
    let suggestion = try JSONDecoder.tailscale().decode(ExitNodeSuggestion.self, from: data)

    XCTAssertEqual(suggestion.id, "nExitNodeStable123")
    XCTAssertEqual(suggestion.name, "us-sfo-wg-101.mullvad.ts.net.")

    let location = try XCTUnwrap(suggestion.location)
    XCTAssertEqual(location.country, "USA")
    XCTAssertEqual(location.countryCode, "US")
    XCTAssertEqual(location.city, "San Francisco, CA")
    XCTAssertEqual(location.cityCode, "SFO")
    XCTAssertEqual(location.latitude ?? 0, 37.774929, accuracy: 0.0001)
    XCTAssertEqual(location.priority, 100)
  }

  func testDecodesSuggestionWithoutLocation() throws {
    let json = Data(#"{"ID": "nSelfHosted1", "Name": "exit-box.tailnet.ts.net."}"#.utf8)
    let suggestion = try JSONDecoder.tailscale().decode(ExitNodeSuggestion.self, from: json)
    XCTAssertEqual(suggestion.id, "nSelfHosted1")
    XCTAssertNil(suggestion.location)
  }
}
