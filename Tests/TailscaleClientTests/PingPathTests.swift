// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

/// Classification of `/localapi/v0/ping` replies into ``PingPath``.
///
/// Fixtures named `ping-captured-*` are real replies from a Tailscale 1.102.2 daemon
/// (provenance and digests in `Fixtures/ping-captured.provenance.json`). Every inline JSON
/// literal below is synthetic and says so: no DERP or peer-relay reply has been captured, so
/// those shapes follow upstream `ipnstate.PingResult` and `cmd/tailscale/cli/ping.go`.
///
/// This file imports `TailscaleClient` without `@testable`, so it also proves the public API.
final class PingPathTests: XCTestCase {
  private func captured(_ name: String) throws -> PingResult {
    let data = try fixture(named: "ping-captured-\(name)", type: "json")
    return try JSONDecoder().decode(PingResult.self, from: data)
  }

  private func synthetic(_ json: String) throws -> PingResult {
    try JSONDecoder().decode(PingResult.self, from: Data(json.utf8))
  }

  // MARK: - Captured replies

  func testCapturedDirectDiscoReplyIsDirect() throws {
    let result = try captured("disco-direct")
    // Upstream encodes every path field; the empty ones must not change the answer.
    XCTAssertEqual(result.error, "")
    XCTAssertEqual(result.peerRelay, "")
    XCTAssertEqual(result.derpRegionID, 0)
    XCTAssertEqual(result.derpRegionCode, "")
    XCTAssertEqual(result.path, .direct(endpoint: "[2001:db8::a]:41641"))
    XCTAssertTrue(result.isDirect)
    XCTAssertTrue(result.isSuccess)
  }

  func testCapturedTSMPICMPAndPeerAPIRepliesHaveUnknownPath() throws {
    for name in ["tsmp", "icmp", "peerapi"] {
      let result = try captured(name)
      XCTAssertEqual(result.endpoint, "", name)
      XCTAssertEqual(result.path, .unknown, name)
      XCTAssertFalse(result.isDirect, "\(name) replies never report a direct path")
      XCTAssertTrue(result.isSuccess, name)
    }
    XCTAssertEqual(try captured("tsmp").peerAPIPort, 42272)
    XCTAssertEqual(try captured("peerapi").nodeName, "example-peer.example.ts.net.")
    XCTAssertEqual(try captured("peerapi").peerAPIURL, "http://100.64.0.2:42272")
  }

  func testCapturedErrorRepliesAreNeverMeasurements() throws {
    let selfIP = try captured("error-self-ip")
    XCTAssertEqual(selfIP.isLocalIP, true)
    XCTAssertEqual(selfIP.error, "100.64.0.1 is local Tailscale IP")

    let expired = try captured("error-expired-key")
    XCTAssertEqual(expired.error, "peer's node key has expired")

    for result in [selfIP, expired] {
      XCTAssertNil(result.path)
      XCTAssertFalse(result.isDirect)
      XCTAssertFalse(result.isSuccess)
    }
  }

  func testReplayingTheSameCaptureYieldsTheSameClassification() throws {
    for name in [
      "disco-direct", "tsmp", "icmp", "peerapi", "error-self-ip", "error-expired-key",
    ] {
      let first = try captured(name)
      for _ in 0..<5 {
        let again = try captured(name)
        XCTAssertEqual(again.path, first.path, name)
        XCTAssertEqual(again.isDirect, first.isDirect, name)
      }
    }
  }

  // MARK: - Synthetic replies (shapes from upstream source, not captured)

  func testSyntheticPeerRelayReply() throws {
    let result = try synthetic(
      """
      {"IP":"100.64.0.2","Err":"","LatencySeconds":0.01,"Endpoint":"",
       "PeerRelay":"203.0.113.7:7777:vni:12","DERPRegionID":0,"DERPRegionCode":""}
      """)
    XCTAssertEqual(result.path, .peerRelay(endpoint: "203.0.113.7:7777:vni:12"))
    XCTAssertFalse(result.isDirect)
  }

  func testSyntheticDERPReplyWithAndWithoutRegionCode() throws {
    let withCode = try synthetic(
      """
      {"IP":"100.64.0.2","Err":"","LatencySeconds":0.08,"Endpoint":"","PeerRelay":"",
       "DERPRegionID":1,"DERPRegionCode":"sfo"}
      """)
    XCTAssertEqual(withCode.path, .derp(regionID: 1, regionCode: "sfo"))
    XCTAssertFalse(withCode.isDirect)

    let emptyCode = try synthetic(
      #"{"IP":"100.64.0.2","Err":"","Endpoint":"","PeerRelay":"","DERPRegionID":7,"DERPRegionCode":""}"#
    )
    XCTAssertEqual(emptyCode.path, .derp(regionID: 7, regionCode: nil))

    let absentCode = try synthetic(#"{"IP":"100.64.0.2","DERPRegionID":7}"#)
    XCTAssertEqual(absentCode.path, .derp(regionID: 7, regionCode: nil))
  }

  func testSyntheticOlderReplyWithoutPeerRelayKey() throws {
    let result = try synthetic(
      """
      {"IP":"100.64.0.2","Err":"","LatencySeconds":0.005,"Endpoint":"192.0.2.10:41641",
       "DERPRegionID":0,"DERPRegionCode":""}
      """)
    XCTAssertNil(result.peerRelay)
    XCTAssertEqual(result.path, .direct(endpoint: "192.0.2.10:41641"))
  }

  func testSyntheticAbsentAndEmptyPathFieldsAreUnknown() throws {
    XCTAssertEqual(try synthetic(#"{"IP":"100.64.0.2"}"#).path, .unknown)
    XCTAssertEqual(try synthetic("{}").path, .unknown)
    let allEmpty = try synthetic(
      #"{"Err":"","Endpoint":"","PeerRelay":"","DERPRegionID":0,"DERPRegionCode":""}"#)
    XCTAssertEqual(allEmpty.path, .unknown)
    XCTAssertFalse(allEmpty.isDirect)
  }

  func testSyntheticUnknownExtraFieldsAreIgnored() throws {
    let result = try synthetic(
      """
      {"IP":"100.64.0.2","Err":"","Endpoint":"192.0.2.10:41641","PeerRelay":"",
       "DERPRegionID":0,"DERPRegionCode":"","FutureField":{"nested":[1,2]},"Another":true}
      """)
    XCTAssertEqual(result.path, .direct(endpoint: "192.0.2.10:41641"))
  }

  func testSyntheticConflictingFieldsFollowUpstreamPrecedence() throws {
    let all = try synthetic(
      """
      {"Err":"","Endpoint":"192.0.2.10:41641","PeerRelay":"203.0.113.7:7777:vni:12",
       "DERPRegionID":1,"DERPRegionCode":"sfo"}
      """)
    XCTAssertEqual(all.path, .peerRelay(endpoint: "203.0.113.7:7777:vni:12"))

    let derpAndEndpoint = try synthetic(
      #"{"Err":"","Endpoint":"192.0.2.10:41641","PeerRelay":"","DERPRegionID":1,"DERPRegionCode":"sfo"}"#
    )
    XCTAssertEqual(derpAndEndpoint.path, .derp(regionID: 1, regionCode: "sfo"))
    XCTAssertFalse(derpAndEndpoint.isDirect)
  }

  func testSyntheticErrorWithPathFieldsIsStillAFailure() throws {
    let result = try synthetic(
      #"{"Err":"timeout","LatencySeconds":0.2,"Endpoint":"192.0.2.10:41641","DERPRegionID":1}"#)
    XCTAssertNil(result.path)
    XCTAssertFalse(result.isDirect)
  }

  func testPathFromMemberwiseInitializer() {
    XCTAssertEqual(
      PingResult(endpoint: "192.0.2.1:41641").path, .direct(endpoint: "192.0.2.1:41641"))
    XCTAssertEqual(PingResult(error: "x", endpoint: "192.0.2.1:41641").path, nil)
    XCTAssertEqual(PingResult().path, .unknown)
    let set: Set<PingPath> = [.unknown, .unknown, .derp(regionID: 1, regionCode: nil)]
    XCTAssertEqual(set.count, 2)
  }

  // MARK: - Wire values

  func testEachPingTypeSendsUpstreamQueryValue() async throws {
    let data = try fixture(named: "ping-captured-icmp", type: "json")
    let expected: [(PingType, String)] = [
      (.disco, "disco"), (.tsmp, "TSMP"), (.icmp, "ICMP"), (.peerAPI, "peerapi"),
    ]
    for (type, wire) in expected {
      let recorder = RequestRecorder()
      let transport = MockTransport { request, _ in
        await recorder.record(request: request)
        return TailscaleResponse(statusCode: 200, data: data)
      }
      let client = TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: .url(URL(string: "http://example.local")!), authToken: nil,
          capabilityVersion: 1, transport: transport))
      _ = try await client.ping(ip: "100.64.0.2", type: type)
      let requests = await recorder.requests
      let request = try XCTUnwrap(requests.first)
      var components = URLComponents()
      components.queryItems = request.queryItems
      XCTAssertEqual(request.path, "/localapi/v0/ping")
      XCTAssertEqual(components.percentEncodedQuery, "ip=100.64.0.2&type=\(wire)")
    }
  }

  func testPingTypeAcceptsThe10Spelling() throws {
    XCTAssertEqual(PingType.peerAPI.rawValue, "peerapi")
    XCTAssertEqual(PingType(rawValue: "peerapi"), .peerAPI)
    XCTAssertEqual(PingType(rawValue: "peerAPI"), .peerAPI)
    XCTAssertNil(PingType(rawValue: "PEERAPI"))
    XCTAssertEqual(
      try JSONDecoder().decode([PingType].self, from: Data(#"["peerAPI","peerapi","TSMP"]"#.utf8)),
      [.peerAPI, .peerAPI, .tsmp])
    XCTAssertEqual(
      String(decoding: try JSONEncoder().encode([PingType.peerAPI]), as: UTF8.self), #"["peerapi"]"#
    )
  }

  // MARK: - 1.0 source compatibility

  /// Compiles only if every 1.0 ping call site still builds unchanged.
  func testOnePointZeroPingCallSitesStillCompile() {
    let result = PingResult(
      ip: "100.64.0.2", nodeIP: "100.64.0.2", nodeName: "example-peer", error: nil,
      latencySeconds: 0.0234, endpoint: "192.0.2.10:41641", peerRelay: nil, derpRegionID: 0,
      derpRegionCode: nil, peerAPIPort: nil, peerAPIURL: nil, isLocalIP: nil)
    let raw: (String?, String?, String?, String?, Double?, String?) = (
      result.ip, result.nodeIP, result.nodeName, result.error, result.latencySeconds,
      result.endpoint
    )
    let more: (String?, Int?, String?, UInt16?, String?, Bool?) = (
      result.peerRelay, result.derpRegionID, result.derpRegionCode, result.peerAPIPort,
      result.peerAPIURL, result.isLocalIP
    )
    let helpers: (Bool, Bool, String?) = (
      result.isDirect, result.isSuccess, result.latencyDescription
    )
    XCTAssertEqual(raw.0, "100.64.0.2")
    XCTAssertEqual(more.1, 0)
    XCTAssertEqual(helpers.0, true)
    XCTAssertEqual(helpers.1, true)
    XCTAssertEqual(helpers.2, "23.40 ms")
    let types: [PingType] = [.disco, .tsmp, .icmp, .peerAPI]
    XCTAssertEqual(types.count, 4)
  }
}
