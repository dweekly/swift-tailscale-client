// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tests for the v0.7.0 lookup surfaces: `peer(byID:)` and
/// `userProfile(byID:)`.
final class PeerLookupTests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  func testPeerByIDDecodesAndSendsID() async throws {
    let data = try fixture(named: "peer-by-id-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }
    let client = makeClient(transport: transport)
    let node = try await client.peer(byID: 1_234_567_890_123_456)

    XCTAssertEqual(node.id, 1_234_567_890_123_456)
    XCTAssertEqual(node.stableID, "nPeerStable123")
    XCTAssertEqual(node.name, "peer.example.ts.net.")
    XCTAssertEqual(node.homeDERP, 2)
    XCTAssertEqual(node.addresses.count, 2)
    XCTAssertEqual(node.tags, ["tag:server"])
    XCTAssertEqual(node.hostinfo?.os, "linux")
    XCTAssertEqual(node.online, true)

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "GET")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/peer-by-id")
    XCTAssertEqual(
      captured.first?.queryItems, [URLQueryItem(name: "id", value: "1234567890123456")])
  }

  func testPeerByIDNotFoundSurfacesAs404() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("no peer with ID".utf8))
    }
    let client = makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.peer(byID: 42)) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, _, let endpoint) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      // 404 here means "peer not found", so it must NOT become
      // endpointUnavailable.
      XCTAssertEqual(code, 404)
      XCTAssertEqual(endpoint, "/localapi/v0/peer-by-id")
    }
  }

  func testUserProfileDecodesAndSendsID() async throws {
    let body = #"""
      {
        "ID": 8646441643364,
        "LoginName": "admin@example.com",
        "DisplayName": "Admin Example",
        "ProfilePicURL": "https://example.com/pic.png",
        "Groups": ["group:eng", "group:ops"]
      }
      """#
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data(body.utf8))
    }
    let client = makeClient(transport: transport)
    let profile = try await client.userProfile(byID: 8_646_441_643_364)

    XCTAssertEqual(profile.id, 8_646_441_643_364)
    XCTAssertEqual(profile.loginName, "admin@example.com")
    XCTAssertEqual(profile.groups, ["group:eng", "group:ops"])

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.path, "/localapi/v0/user-profile")
    XCTAssertEqual(
      captured.first?.queryItems, [URLQueryItem(name: "id", value: "8646441643364")])
  }

  func testUserProfileWithoutGroupsDecodesToEmpty() throws {
    let body = #"{"ID": 7, "LoginName": "a@b.c"}"#
    let profile = try JSONDecoder.tailscale().decode(UserProfile.self, from: Data(body.utf8))
    XCTAssertTrue(profile.groups.isEmpty)
  }
}
