// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

/// Consumer validation test suite simulating the TailscaleFleetAgent configuration management daemon.
///
/// FleetAgent manages workstation and server lifecycle, multi-tenant login profiles,
/// selective preference isolation, and Serve/Funnel microservice route bindings.
/// This test suite validates these mutation workflows strictly without `@testable import`.
final class FleetAgentConfigurationTests: XCTestCase {

  // MARK: - 1. Profile Switching & Listing

  func testProfileSwitching() async throws {
    let profilesJSON = """
      [
        {"ID": "prof-work", "Name": "Corp Workplace", "Key": "k1"},
        {"ID": "prof-personal", "Name": "Home Lab", "Key": "k2"}
      ]
      """

    let currentJSON = """
      {"ID": "prof-work", "Name": "Corp Workplace", "Key": "k1"}
      """

    let recorder = RequestRecorder()

    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      if request.path == "/localapi/v0/profiles/" {
        return TailscaleResponse(statusCode: 200, data: Data(profilesJSON.utf8))
      }
      if request.path == "/localapi/v0/profiles/current" {
        return TailscaleResponse(statusCode: 200, data: Data(currentJSON.utf8))
      }
      if request.path == "/localapi/v0/profiles/prof-personal", request.method == "POST" {
        return TailscaleResponse(statusCode: 200, data: Data())
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // 1. List profiles
    let profiles = try await client.profiles()
    XCTAssertEqual(profiles.count, 2)
    XCTAssertEqual(profiles[0].id, "prof-work")
    XCTAssertEqual(profiles[0].name, "Corp Workplace")
    XCTAssertEqual(profiles[1].id, "prof-personal")

    // 2. Query current profile
    let current = try await client.currentProfile()
    XCTAssertEqual(current.id, "prof-work")

    // 3. Switch to personal profile
    try await client.switchProfile("prof-personal")

    let recordedRequests = await recorder.requests
    let switchRequest = recordedRequests.first { $0.path == "/localapi/v0/profiles/prof-personal" }
    XCTAssertNotNil(switchRequest)
    XCTAssertEqual(switchRequest?.method, "POST")
  }

  // MARK: - 2. Clean-Slate Empty Profile Creation

  func testCleanSlateEmptyProfileCreation() async throws {
    let recorder = RequestRecorder()

    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      if request.path == "/localapi/v0/profiles/", request.method == "PUT" {
        return TailscaleResponse(statusCode: 201, data: Data("{}".utf8))
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // switchToEmptyProfile creates a new profile and switches to it (PUT /localapi/v0/profiles/)
    try await client.switchToEmptyProfile()

    let recorded = await recorder.requests
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded[0].method, "PUT")
    XCTAssertEqual(recorded[0].path, "/localapi/v0/profiles/")
  }

  // MARK: - 3. Masked Preferences Isolation via MaskedPrefs

  func testMaskedPreferencesIsolation() async throws {
    let recorder = RequestRecorder()

    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(
        statusCode: 200,
        data: Data("{\"ExitNodeID\": \"nExitNode123\", \"ShieldsUp\": true}".utf8)
      )
    }

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // Fleet agent adjusts exit node and shields up without modifying other settings
    var patch = MaskedPrefs()
    patch.exitNodeID = "nExitNode123"
    patch.shieldsUp = true
    patch.exitNodeAllowLANAccess = false

    _ = try await client.editPrefs(patch)

    let requests = await recorder.requests
    XCTAssertEqual(requests.count, 1)
    let req = requests[0]
    XCTAssertEqual(req.method, "PATCH")
    XCTAssertEqual(req.path, "/localapi/v0/prefs")

    guard let body = req.body else {
      XCTFail("Expected request body")
      return
    }

    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )

    // Verify targeted fields are set along with their <Name>Set flags
    XCTAssertEqual(json["ExitNodeID"] as? String, "nExitNode123")
    XCTAssertEqual(json["ExitNodeIDSet"] as? Bool, true)

    XCTAssertEqual(json["ShieldsUp"] as? Bool, true)
    XCTAssertEqual(json["ShieldsUpSet"] as? Bool, true)

    XCTAssertEqual(json["ExitNodeAllowLANAccess"] as? Bool, false)
    XCTAssertEqual(json["ExitNodeAllowLANAccessSet"] as? Bool, true)

    // Verify untouched fields are NOT present in the payload
    XCTAssertNil(json["RouteAllSet"])
    XCTAssertNil(json["CorpDNSSet"])
    XCTAssertNil(json["RunSSHSet"])
    XCTAssertNil(json["HostnameSet"])
  }

  // MARK: - 4. ServeConfigSnapshot Optimistic Concurrency Conflict & Retry

  func testServeConfigConflictDetectionAndRetry() async throws {
    actor DaemonServeState {
      var writeAttempts = 0
      var currentEtag = "etag-v1"
      var currentConfigJSON = """
        {
          "TCP": {
            "8080": {
              "TCPForward": "127.0.0.1:3000"
            }
          }
        }
        """

      func get() -> (String, String) {
        (currentEtag, currentConfigJSON)
      }

      func post(ifMatch: String?, body: Data) -> (Int, [String: String], Data) {
        writeAttempts += 1
        if writeAttempts == 1 {
          // Simulate concurrent edit between snapshot read and write
          currentEtag = "etag-v2"
          currentConfigJSON = """
            {
              "TCP": {
                "8080": {"TCPForward": "127.0.0.1:3000"},
                "9090": {"TCPForward": "127.0.0.1:4000"}
              }
            }
            """
          return (412, [:], Data("412 Precondition Failed: ETag mismatch".utf8))
        } else {
          currentEtag = "etag-v3"
          return (200, ["ETag": "etag-v3"], body)
        }
      }

      var attempts: Int { writeAttempts }
    }

    let daemon = DaemonServeState()

    let transport = MockTransport { request, _ in
      if request.path == "/localapi/v0/serve-config" {
        if request.method == "GET" {
          let (etag, jsonStr) = await daemon.get()
          return TailscaleResponse(
            statusCode: 200,
            data: Data(jsonStr.utf8),
            headers: ["ETag": etag]
          )
        } else if request.method == "POST" {
          let ifMatch = request.additionalHeaders["If-Match"]
          let (status, headers, data) = await daemon.post(
            ifMatch: ifMatch, body: request.body ?? Data())
          return TailscaleResponse(statusCode: status, data: data, headers: headers)
        }
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // 1. Fetch initial snapshot (etag-v1)
    let snapshot1 = try await client.serveConfigSnapshot()
    XCTAssertEqual(snapshot1.etag, "etag-v1")
    XCTAssertNotNil(snapshot1.config.tcp[8080])

    // 2. Attempt update using stale snapshot1 -> fails with HTTP 412 (preconditionFailed)
    do {
      _ = try await client.updateServeConfig(snapshot1) { config in
        config.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:5000")
      }
      XCTFail("Expected preconditionFailed error on stale ETag")
    } catch TailscaleClientError.preconditionFailed {
      // Expected conflict caught!
    }

    // 3. Re-fetch fresh snapshot (etag-v2) and retry update -> succeeds with etag-v3
    let snapshot2 = try await client.serveConfigSnapshot()
    XCTAssertEqual(snapshot2.etag, "etag-v2")
    XCTAssertNotNil(snapshot2.config.tcp[9090])

    let snapshot3 = try await client.updateServeConfig(snapshot2) { config in
      config.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:5000")
    }
    XCTAssertEqual(snapshot3.etag, "etag-v3")
    XCTAssertNotNil(snapshot3.config.tcp[8443])

    let attempts = await daemon.attempts
    XCTAssertEqual(attempts, 2, "Must have performed two write attempts (1 conflict + 1 success)")
  }

  // MARK: - 5. Lossless Unmodeled Field Preservation

  func testLosslessUnmodeledFieldPreservation() throws {
    let rawServeJSON = """
      {
        "TCP": {
          "443": {
            "HTTPS": true,
            "TCPForward": "127.0.0.1:8000",
            "UnmodeledTCPField": "preserve-tcp"
          }
        },
        "Web": {
          "host.example.com:443": {
            "Handlers": {
              "/": {
                "Proxy": "http://127.0.0.1:3000",
                "UnmodeledHandlerField": 42
              }
            },
            "UnmodeledWebField": true
          }
        },
        "UnmodeledRootString": "custom-root-setting",
        "Unmodeled64BitInt": 9223372036854775807
      }
      """

    let decoder = JSONDecoder()
    let initialConfig = try decoder.decode(ServeConfig.self, from: Data(rawServeJSON.utf8))

    // Assert initial unmodeled values parsed correctly
    XCTAssertEqual(
      initialConfig.unmodeledFields["UnmodeledRootString"], .string("custom-root-setting"))
    XCTAssertEqual(
      initialConfig.unmodeledFields["Unmodeled64BitInt"], .integer(Int64.max))

    let tcp443 = try XCTUnwrap(initialConfig.tcp[443])
    XCTAssertEqual(tcp443.unmodeledFields["UnmodeledTCPField"], .string("preserve-tcp"))

    let webConfig = try XCTUnwrap(initialConfig.web["host.example.com:443"])
    XCTAssertEqual(webConfig.unmodeledFields["UnmodeledWebField"], .bool(true))
    let handler = try XCTUnwrap(webConfig.handlers["/"])
    XCTAssertEqual(handler.unmodeledFields["UnmodeledHandlerField"], .integer(42))

    // Mutate a known field
    var mutated = initialConfig
    mutated.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:9000")

    // Encode back to JSON
    let encoder = JSONEncoder()
    let encodedData = try encoder.encode(mutated)

    // Redecode and verify unmodeled fields survived intact
    let redecoded = try decoder.decode(ServeConfig.self, from: encodedData)
    XCTAssertEqual(
      redecoded.unmodeledFields["UnmodeledRootString"], .string("custom-root-setting"))
    XCTAssertEqual(
      redecoded.unmodeledFields["Unmodeled64BitInt"], .integer(Int64.max))
    XCTAssertEqual(
      redecoded.tcp[443]?.unmodeledFields["UnmodeledTCPField"], .string("preserve-tcp"))
    XCTAssertEqual(
      redecoded.web["host.example.com:443"]?.unmodeledFields["UnmodeledWebField"], .bool(true))
    XCTAssertEqual(
      redecoded.web["host.example.com:443"]?.handlers["/"]?.unmodeledFields[
        "UnmodeledHandlerField"], .integer(42))

    // Verify added port is also present
    XCTAssertEqual(redecoded.tcp[8443]?.tcpForward, "127.0.0.1:9000")
  }

  // MARK: - 6. Unconditional Serve Replacement

  func testUnconditionalReplacement() async throws {
    let recorder = RequestRecorder()

    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    var newConfig = ServeConfig()
    newConfig.tcp[443] = TCPPortHandler(tcpForward: "127.0.0.1:8080")

    try await client.replaceServeConfigUnconditionally(newConfig)

    let requests = await recorder.requests
    XCTAssertEqual(requests.count, 1)
    let req = requests[0]
    XCTAssertEqual(req.method, "POST")
    XCTAssertEqual(req.path, "/localapi/v0/serve-config")
    XCTAssertEqual(
      req.additionalHeaders["If-Match"], "",
      "Unconditional replacement must send empty If-Match header to bypass concurrency check")
  }
}
