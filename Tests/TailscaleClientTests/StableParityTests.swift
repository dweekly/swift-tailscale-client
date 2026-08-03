// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

private let whoisBody = Data(#"{"Node": {"ID": 1, "StableID": "n1"}}"#.utf8)

/// Tests for the stable-parity surface (upstream-readiness issue 04): whois
/// variants, checkUpdate, disconnectControl, switchToEmptyProfile,
/// checkUDPGROForwarding, and the supported
/// bugReport facade.
final class StableParityTests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - WhoIs variants

  func testWhoIsProtoSendsProtoAndAddr() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: whoisBody)
    }
    _ = try await makeClient(transport: transport)
      .whois(address: "100.64.0.5:443", protocol: .tcp)

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.path, "/localapi/v0/whois")
    XCTAssertEqual(
      request.queryItems,
      [
        URLQueryItem(name: "proto", value: "tcp"),
        URLQueryItem(name: "addr", value: "100.64.0.5:443"),
      ])
  }

  func testWhoIsNodeKeySendsKeyAsAddr() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: whoisBody)
    }
    let key = "nodekey:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
    _ = try await makeClient(transport: transport).whois(nodeKey: key)

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.queryItems, [URLQueryItem(name: "addr", value: key)])
  }

  func testWhoIsForIPSendsDstIP() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: whoisBody)
    }
    _ = try await makeClient(transport: transport)
      .whois(address: "100.64.0.5", scopedToDestination: "100.100.5.1")

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(
      request.queryItems,
      [
        URLQueryItem(name: "addr", value: "100.64.0.5"),
        URLQueryItem(name: "dst_ip", value: "100.100.5.1"),
      ])
  }

  func testWhoIsForServiceSendsServiceName() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: whoisBody)
    }
    _ = try await makeClient(transport: transport)
      .whois(address: "100.64.0.5", forService: "svc:web")

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(
      request.queryItems,
      [
        URLQueryItem(name: "addr", value: "100.64.0.5"),
        URLQueryItem(name: "svc_name", value: "svc:web"),
      ])
  }

  func testWhoIsVariantMaps404ToPeerNotFound() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("no match".utf8))
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).whois(address: "1.2.3.4", protocol: .udp)
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .peerNotFound(let endpoint) = clientError
      else {
        XCTFail("Expected .peerNotFound, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/whois")
    }
  }

  // MARK: - checkUpdate

  func testCheckUpdateDecodesClientVersion() async throws {
    // Realistic available-update wire shape: upstream marks every boolean
    // omitempty, so RunningLatest is ABSENT (not false) when an update
    // exists. Absent must decode as false.
    let json = #"""
      {"LatestVersion": "1.99.2",
       "UrgentSecurityUpdate": true, "Notify": true,
       "NotifyURL": "https://tailscale.com/changelog",
       "NotifyText": "Security update available"}
      """#
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.path, "/localapi/v0/update/check")
      return TailscaleResponse(statusCode: 200, data: Data(json.utf8))
    }
    let version = try await makeClient(transport: transport).checkUpdate()
    XCTAssertFalse(
      version.runningLatest, "Omitted RunningLatest (omitempty false) must decode as false")
    XCTAssertEqual(version.latestVersion, "1.99.2")
    XCTAssertTrue(version.urgentSecurityUpdate)
    XCTAssertEqual(version.notifyText, "Security update available")
  }

  func testCheckUpdateDecodesUpToDateShape() async throws {
    // The up-to-date answer carries only RunningLatest; every omitempty
    // boolean the daemon omits must land as false, not nil-masquerading.
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(#"{"RunningLatest": true}"#.utf8))
    }
    let version = try await makeClient(transport: transport).checkUpdate()
    XCTAssertTrue(version.runningLatest)
    XCTAssertFalse(version.urgentSecurityUpdate)
    XCTAssertFalse(version.notify)
    XCTAssertNil(version.latestVersion)
  }

  func testCheckUpdateMaps404ToEndpointUnavailable() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("404 page not found".utf8))
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).checkUpdate()
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(_, let feature) = clientError
      else {
        XCTFail("Expected .endpointUnavailable, got \(error)")
        return
      }
      XCTAssertEqual(feature, "clientupdate")
    }
  }

  // MARK: - disconnectControl / switchToEmptyProfile

  func testDisconnectControlPostsAndAcceptsPlain200() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data())
    }
    try await makeClient(transport: transport).disconnectControl()

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/localapi/v0/disconnect-control")
  }

  func testDisconnectControlMaps404ToEndpointUnavailable() async throws {
    // Upstream registers the endpoint only when HasDebug or
    // HasAdvertiseRoutes is compiled in; a feature-minimal daemon's 404 must
    // surface as the typed unavailability, not a generic status error.
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("404 page not found".utf8))
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).disconnectControl()
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable = clientError
      else {
        XCTFail("Expected .endpointUnavailable, got \(error)")
        return
      }
    }
  }

  func testSwitchToEmptyProfileAccepts201Created() async throws {
    // Mirrors upstream SwitchToEmptyProfile: PUT /profiles/, and the daemon
    // answers exactly 201 Created.
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 201, data: Data())
    }
    try await makeClient(transport: transport).switchToEmptyProfile()

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.method, "PUT")
    XCTAssertEqual(request.path, "/localapi/v0/profiles/")
  }

  // MARK: - checkUDPGROForwarding

  func testCheckUDPGROForwardingParsesWarning() async throws {
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.path, "/localapi/v0/check-udp-gro-forwarding")
      return TailscaleResponse(
        statusCode: 200, data: Data(#"{"Warning": "GRO forwarding is not enabled"}"#.utf8))
    }
    let check = try await makeClient(transport: transport).checkUDPGROForwarding()
    XCTAssertFalse(check.isReady)
    XCTAssertEqual(check.warning, "GRO forwarding is not enabled")
  }

  func testCheckUDPGROForwardingHealthyOnEmptyObject() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let check = try await makeClient(transport: transport).checkUDPGROForwarding()
    XCTAssertTrue(check.isReady)
  }

  // MARK: - bugReport supported facade

  func testBugReportReturnsTrimmedMarker() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("BUG-1234abcd\n".utf8))
    }
    let marker = try await makeClient(transport: transport).bugReport(note: "recipe test")
    XCTAssertEqual(marker, "BUG-1234abcd")

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/localapi/v0/bugreport")
    XCTAssertEqual(request.queryItems, [URLQueryItem(name: "note", value: "recipe test")])
  }
}
