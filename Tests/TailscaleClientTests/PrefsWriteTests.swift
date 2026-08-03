// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tests for the v0.8.0 write surfaces: `editPrefs(_:)`, `checkPrefs(_:)`,
/// and `setUseExitNode(enabled:)`.
final class PrefsWriteTests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  private func jsonObject(_ data: Data?) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data ?? Data())
    return try XCTUnwrap(object as? [String: Any])
  }

  // MARK: - MaskedPrefs encoding

  func testMaskedPrefsEncodesValueAndFlagPairs() throws {
    var masked = MaskedPrefs()
    masked.exitNodeID = "nExitNodeStable123"
    masked.exitNodeAllowLANAccess = true
    masked.shieldsUp = false
    masked.advertiseRoutes = ["10.0.0.0/24"]

    let wire = try jsonObject(JSONEncoder().encode(masked))
    XCTAssertEqual(wire["ExitNodeID"] as? String, "nExitNodeStable123")
    XCTAssertEqual(wire["ExitNodeIDSet"] as? Bool, true)
    XCTAssertEqual(wire["ExitNodeAllowLANAccess"] as? Bool, true)
    XCTAssertEqual(wire["ExitNodeAllowLANAccessSet"] as? Bool, true)
    XCTAssertEqual(wire["ShieldsUp"] as? Bool, false)
    XCTAssertEqual(wire["ShieldsUpSet"] as? Bool, true)
    XCTAssertEqual(wire["AdvertiseRoutes"] as? [String], ["10.0.0.0/24"])
    XCTAssertEqual(wire["AdvertiseRoutesSet"] as? Bool, true)

    // Untouched fields must appear neither as values nor as flags.
    XCTAssertNil(wire["RouteAll"])
    XCTAssertNil(wire["RouteAllSet"])
    XCTAssertNil(wire["AutoUpdate"])
  }

  func testMaskedPrefsEncodesNestedAutoUpdateMask() throws {
    var masked = MaskedPrefs()
    masked.autoUpdateCheck = true

    let wire = try jsonObject(JSONEncoder().encode(masked))
    let value = try XCTUnwrap(wire["AutoUpdate"] as? [String: Any])
    let mask = try XCTUnwrap(wire["AutoUpdateSet"] as? [String: Any])
    XCTAssertEqual(value["Check"] as? Bool, true)
    XCTAssertEqual(mask["CheckSet"] as? Bool, true)
    XCTAssertNil(value["Apply"])
    XCTAssertNil(mask["ApplySet"])
  }

  func testEmptyMaskedPrefsEncodesToEmptyObject() throws {
    let masked = MaskedPrefs()
    XCTAssertTrue(masked.isEmpty)
    let wire = try jsonObject(JSONEncoder().encode(masked))
    XCTAssertTrue(wire.isEmpty)
  }

  // MARK: - editPrefs

  func testEditPrefsPATCHesBodyAndDecodesResponse() async throws {
    let responseData = try fixture(named: "prefs-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: responseData)
    }
    let client = makeClient(transport: transport)

    var masked = MaskedPrefs()
    masked.wantRunning = true
    let updated = try await client.editPrefs(masked)

    XCTAssertEqual(updated.wantRunning, true)

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "PATCH")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/prefs")
    let body = try jsonObject(captured.first?.body)
    XCTAssertEqual(body["WantRunning"] as? Bool, true)
    XCTAssertEqual(body["WantRunningSet"] as? Bool, true)
  }

  func testEditPrefsSurfacesValidationErrors() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 400, data: Data("exit node not found".utf8))
    }
    let client = makeClient(transport: transport)

    var masked = MaskedPrefs()
    masked.exitNodeID = "nBogus"
    await assertThrowsErrorAsync(try await client.editPrefs(masked)) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, let body, _) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      XCTAssertEqual(code, 400)
      XCTAssertEqual(String(data: body, encoding: .utf8), "exit node not found")
    }
  }

  // MARK: - checkPrefs

  func testCheckPrefsPOSTsFullPrefs() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = makeClient(transport: transport)

    let prefsData = try fixture(named: "prefs-sample", type: "json")
    let prefs = try JSONDecoder.tailscale().decode(Prefs.self, from: prefsData)
    try await client.checkPrefs(prefs)

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/check-prefs")
    let body = try jsonObject(captured.first?.body)
    XCTAssertEqual(body["ControlURL"] as? String, "https://controlplane.tailscale.com")
  }

  func testCheckPrefsSurfacesRejection() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 400, data: Data("routeAll requires...".utf8))
    }
    let client = makeClient(transport: transport)
    let prefs = try JSONDecoder.tailscale().decode(
      Prefs.self, from: try fixture(named: "prefs-sample", type: "json"))

    await assertThrowsErrorAsync(try await client.checkPrefs(prefs)) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(400, _, _) = clientError
      else {
        XCTFail("Expected unexpectedStatus(400), got \(error)")
        return
      }
    }
  }

  func testCheckPrefsThrowsOnDaemonReportedError() async throws {
    // The daemon reports invalid prefs as HTTP 200 with an Error field.
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200, data: Data(#"{"Error": "exit node not found"}"#.utf8))
    }
    let client = makeClient(transport: transport)
    let prefs = try JSONDecoder.tailscale().decode(
      Prefs.self, from: try fixture(named: "prefs-sample", type: "json"))

    await assertThrowsErrorAsync(try await client.checkPrefs(prefs)) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, let body, _) = clientError
      else {
        XCTFail("Expected unexpectedStatus, got \(error)")
        return
      }
      XCTAssertEqual(code, 200)
      XCTAssertEqual(String(data: body, encoding: .utf8), "exit node not found")
    }
  }

  func testCheckPrefsAcceptsEmptyErrorAsValid() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(#"{"Error": ""}"#.utf8))
    }
    let client = makeClient(transport: transport)
    let prefs = try JSONDecoder.tailscale().decode(
      Prefs.self, from: try fixture(named: "prefs-sample", type: "json"))
    try await client.checkPrefs(prefs)  // must not throw
  }

  func testCheckPrefsFailsClosedOnMalformedResponses() async throws {
    // A validity check must never treat garbage as approval.
    let prefs = try JSONDecoder.tailscale().decode(
      Prefs.self, from: try fixture(named: "prefs-sample", type: "json"))

    for body in ["not json at all", #"{"Error": 123}"#, ""] {
      let transport = MockTransport { _, _ in
        TailscaleResponse(statusCode: 200, data: Data(body.utf8))
      }
      let client = makeClient(transport: transport)
      await assertThrowsErrorAsync(try await client.checkPrefs(prefs)) { error in
        guard let clientError = error as? TailscaleClientError,
          case .decoding = clientError
        else {
          XCTFail("Malformed body \(body) must fail closed with .decoding, got \(error)")
          return
        }
      }
    }
  }

  func testCheckPrefsTreatsUnknownFieldsAsValid() async throws {
    // Unknown *extra* fields are fine (tolerant decoding); only a malformed
    // or missing contract shape fails.
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(#"{"Error": "", "Future": true}"#.utf8))
    }
    let client = makeClient(transport: transport)
    let prefs = try JSONDecoder.tailscale().decode(
      Prefs.self, from: try fixture(named: "prefs-sample", type: "json"))
    try await client.checkPrefs(prefs)
  }

  // MARK: - setUseExitNode

  func testSetUseExitNodeSendsQueryAndDecodesPrefs() async throws {
    let responseData = try fixture(named: "prefs-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: responseData)
    }
    let client = makeClient(transport: transport)
    _ = try await client.setUseExitNode(enabled: true)

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/set-use-exit-node-enabled")
    XCTAssertEqual(
      captured.first?.queryItems, [URLQueryItem(name: "enabled", value: "true")])
  }

  // MARK: - Daemon control

  func testSetExpirySoonerSendsUnixTimestamp() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("done\n".utf8))
    }
    let client = makeClient(transport: transport)
    try await client.setExpirySooner(Date(timeIntervalSince1970: 1_800_000_000))

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/set-expiry-sooner")
    XCTAssertEqual(
      captured.first?.queryItems, [URLQueryItem(name: "expiry", value: "1800000000")])
  }

  func testReloadConfigDecodesOutcome() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(#"{"Reloaded": true}"#.utf8))
    }
    let client = makeClient(transport: transport)
    let result = try await client.reloadConfig()
    XCTAssertTrue(result.reloaded)
    XCTAssertNil(result.error)
  }

  func testReloadConfigCarriesDaemonError() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200, data: Data(#"{"Reloaded": false, "Err": "parse error"}"#.utf8))
    }
    let client = makeClient(transport: transport)
    let result = try await client.reloadConfig()
    XCTAssertFalse(result.reloaded)
    XCTAssertEqual(result.error, "parse error")
  }

  func testStartPOSTsOptionsAndAccepts204() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 204, data: Data())
    }
    let client = makeClient(transport: transport)
    try await client.start(options: StartOptions(authKey: "tskey-auth-xyz"))

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/start")
    let body = try jsonObject(captured.first?.body)
    XCTAssertEqual(body["AuthKey"] as? String, "tskey-auth-xyz")
  }

  func testStartEncodesUpdatePrefsWithWireKeys() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 204, data: Data())
    }
    let client = makeClient(transport: transport)
    try await client.start(
      options: StartOptions(
        updatePrefs: Prefs(controlURL: "http://127.0.0.1:8080", wantRunning: true)))

    let body = try jsonObject((await recorder.requests).first?.body)
    XCTAssertNil(body["AuthKey"], "unset fields must stay off the wire")
    let updatePrefs = try XCTUnwrap(body["UpdatePrefs"] as? [String: Any])
    XCTAssertEqual(updatePrefs["ControlURL"] as? String, "http://127.0.0.1:8080")
    XCTAssertEqual(updatePrefs["WantRunning"] as? Bool, true)
    XCTAssertNil(updatePrefs["CorpDNS"], "nil prefs fields must stay off the wire")
  }

  func testStartWithDefaultsSendsEmptyObject() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 204, data: Data())
    }
    let client = makeClient(transport: transport)
    try await client.start()

    let body = try jsonObject((await recorder.requests).first?.body)
    XCTAssertTrue(body.isEmpty)
  }

  func testSetUseExitNodeMaps501ToEndpointUnavailable() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 501, data: Data("feature not available".utf8))
    }
    let client = makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.setUseExitNode(enabled: false)) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(_, let feature) = clientError
      else {
        XCTFail("Expected endpointUnavailable error, got \(error)")
        return
      }
      XCTAssertEqual(feature, "use-exit-node")
    }
  }
}
