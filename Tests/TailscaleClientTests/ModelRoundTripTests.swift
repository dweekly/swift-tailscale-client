// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

/// The response models became `Codable` (not just `Decodable`) in v0.6.0 so
/// apps and the CLI can re-serialize them (`--json` output, caching). These
/// tests pin the encode side: whatever we encode must decode back equal.
final class ModelRoundTripTests: XCTestCase {

  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder.tailscale()
    return try decoder.decode(T.self, from: encoder.encode(value))
  }

  func testStatusResponseRoundTrips() throws {
    // Whole-second dates: ISO8601 encoding drops sub-second precision, so
    // fractional inputs would not compare equal after the trip.
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let status = StatusResponse(
      version: "1.99.0",
      backendState: .running,
      tailscaleIPs: ["100.64.0.1"],
      selfNode: NodeStatus(
        id: "n1", publicKey: "nodekey:abc", hostName: "host", dnsName: "host.ts.net.",
        created: created,
        online: true,
        capabilityMap: [
          "https://tailscale.com/cap/is-admin": .null,
          "default-auto-update": .booleans([false]),
          "mixed": .raw([.string("a"), .integer(1)]),
        ]),
      peers: [
        "nodekey:peer1": NodeStatus(
          id: "n2", publicKey: "nodekey:peer1", hostName: "peer", dnsName: "peer.ts.net.")
      ],
      currentTailnet: TailnetStatus(name: "example.com", magicDNSEnabled: true),
      health: ["warning-1"])

    XCTAssertEqual(try roundTrip(status), status)
  }

  func testBackendStateOtherEncodesToKnownString() throws {
    let data = try JSONEncoder().encode(BackendState.other)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"Other\"")
  }

  func testWhoIsResponseRoundTrips() throws {
    let response = WhoIsResponse(
      node: WhoIsNode(
        id: 42, stableID: "stable42", name: "box.example.ts.net.",
        addresses: ["100.64.0.9/32"],
        hostinfo: WhoIsHostinfo(os: "linux", hostname: "box"),
        tags: ["tag:server"]),
      userProfile: UserProfile(id: 7, loginName: "admin@example.com"),
      capMap: ["cap": .strings(["x"])])

    XCTAssertEqual(try roundTrip(response), response)
  }

  func testPingResultRoundTrips() throws {
    let result = PingResult(
      ip: "100.64.0.5", nodeIP: "100.64.0.5", nodeName: "peer",
      latencySeconds: 0.0123, endpoint: "203.0.113.9:41641")
    XCTAssertEqual(try roundTrip(result), result)
  }
}
