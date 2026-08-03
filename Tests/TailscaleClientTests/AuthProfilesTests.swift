// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tests for the v0.9.0 auth/profile surfaces. The destructive calls
/// (logout, resetAuth, deleteProfile) are verified at the wire-shape level
/// only — no integration test ever runs them.
final class AuthProfilesTests: XCTestCase {

  private func recordedClient(
    status: Int = 204, body: Data = Data(), recorder: RequestRecorder
  ) -> TailscaleClient {
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: status, data: body)
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  func testLoginLogoutResetAuthShapes() async throws {
    let recorder = RequestRecorder()
    let client = recordedClient(recorder: recorder)

    try await client.loginInteractive()
    try await client.logout()
    try await client.resetAuth()

    let captured = await recorder.requests
    XCTAssertEqual(captured.map(\.method), ["POST", "POST", "POST"])
    XCTAssertEqual(
      captured.map(\.path),
      [
        "/localapi/v0/login-interactive",
        "/localapi/v0/logout",
        "/localapi/v0/reset-auth",
      ])
    XCTAssertTrue(captured.allSatisfy { $0.body == nil && $0.queryItems.isEmpty })
  }

  func testProfilesListDecodesFixture() async throws {
    let data = try fixture(named: "profiles-sample", type: "json")
    let recorder = RequestRecorder()
    let client = recordedClient(status: 200, body: data, recorder: recorder)

    let profiles = try await client.profiles()
    XCTAssertEqual(profiles.count, 2)
    XCTAssertEqual(profiles.first?.id, "48d1")
    XCTAssertEqual(profiles.first?.networkProfile?.displayName, "example-corp")
    XCTAssertEqual(profiles.first?.userProfile?.loginName, "admin@example.com")
    XCTAssertNotNil(profiles.first?.created)
    XCTAssertEqual(profiles.last?.controlURL, "https://headscale.example.com")
    XCTAssertNil(profiles.last?.networkProfile)

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.path, "/localapi/v0/profiles/")
  }

  func testCurrentProfileDecodes() async throws {
    let body = Data(#"{"ID": "48d1", "Name": "admin@example.com"}"#.utf8)
    let recorder = RequestRecorder()
    let client = recordedClient(status: 200, body: body, recorder: recorder)

    let current = try await client.currentProfile()
    XCTAssertEqual(current.id, "48d1")
    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.path, "/localapi/v0/profiles/current")
  }

  func testProfileLifecycleShapes() async throws {
    let recorder = RequestRecorder()
    let client = recordedClient(status: 201, recorder: recorder)

    try await client.switchToEmptyProfile()
    try await client.switchProfile("9f2c")
    try await client.deleteProfile("9f2c")

    let captured = await recorder.requests
    XCTAssertEqual(captured.map(\.method), ["PUT", "POST", "DELETE"])
    XCTAssertEqual(
      captured.map(\.path),
      [
        "/localapi/v0/profiles/",
        "/localapi/v0/profiles/9f2c",
        "/localapi/v0/profiles/9f2c",
      ])
  }

  func testIDTokenSendsAudienceAndMaps501() async throws {
    let recorder = RequestRecorder()
    let client = recordedClient(
      status: 200, body: Data(#"{"id_token": "eyJ..."}"#.utf8), recorder: recorder)

    let raw = try await client.idToken(audience: "https://ci.example.com")
    XCTAssertTrue(raw.contains("id_token"))
    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/id-token")
    XCTAssertEqual(
      captured.first?.queryItems,
      [URLQueryItem(name: "aud", value: "https://ci.example.com")])

    let unavailable = MockTransport { _, _ in
      TailscaleResponse(statusCode: 501, data: Data())
    }
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil, capabilityVersion: 1, transport: unavailable)
    await assertThrowsErrorAsync(
      try await TailscaleClient(configuration: config).idToken(audience: "x")
    ) { error in
      guard case .endpointUnavailable = error as? TailscaleClientError else {
        XCTFail("Expected endpointUnavailable, got \(error)")
        return
      }
    }
  }
}
