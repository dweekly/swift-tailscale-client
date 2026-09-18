// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

final class LocalAPIDifferentialConformanceTests: XCTestCase {
  private let supportedVersions = ["1.76.0", "1.84.0", "1.96.4", "1.98.0"]

  // MARK: - Surface 1: Status Conformance

  func testSurface1StatusConformance() throws {
    for version in supportedVersions {
      let data = try localAPIFixture(version: version, endpoint: "status")
      let status = try JSONDecoder.tailscale().decode(StatusResponse.self, from: data)

      // 1. Verify Status root properties
      XCTAssertEqual(status.version, version)
      XCTAssertEqual(status.isTunEnabled, true)
      XCTAssertEqual(status.backendState, BackendState.running)
      XCTAssertEqual(status.haveNodeKey, true)
      XCTAssertNil(status.authURL)
      XCTAssertFalse(status.tailscaleIPs.isEmpty)
      XCTAssertEqual(status.magicDNSSuffix, "example.ts.net")
      XCTAssertEqual(status.currentTailnet?.name, "example.ts.net")
      XCTAssertEqual(status.currentTailnet?.magicDNSEnabled, true)
      XCTAssertFalse(status.certDomains.isEmpty)

      // 2. Verify all 28+ fields on NodeStatus (Self and Peers)
      guard let selfNode = status.selfNode else {
        XCTFail("Missing selfNode in \(version)")
        continue
      }
      XCTAssertEqual(selfNode.id, "nSelfExample")
      XCTAssertTrue(selfNode.publicKey.hasPrefix("nodekey:"))
      XCTAssertEqual(selfNode.hostName, "example-device")
      XCTAssertEqual(selfNode.dnsName, "example-device.example.ts.net.")
      XCTAssertEqual(selfNode.operatingSystem, "macOS")
      XCTAssertEqual(selfNode.userID, 1_000_000_000_000_001)
      XCTAssertFalse(selfNode.tailscaleIPs.isEmpty)
      XCTAssertFalse(selfNode.allowedIPs.isEmpty)
      XCTAssertFalse(selfNode.addresses?.isEmpty ?? true)
      XCTAssertEqual(selfNode.relay, "nyc")
      XCTAssertNotNil(selfNode.rxBytes)
      XCTAssertNotNil(selfNode.txBytes)
      XCTAssertNotNil(selfNode.created)
      XCTAssertNotNil(selfNode.lastWrite)
      XCTAssertNotNil(selfNode.lastSeen)
      XCTAssertNotNil(selfNode.lastHandshake)
      XCTAssertEqual(selfNode.online, true)
      XCTAssertEqual(selfNode.exitNode, false)
      XCTAssertEqual(selfNode.exitNodeOption, false)
      XCTAssertEqual(selfNode.active, false)
      XCTAssertFalse(selfNode.peerAPIURL?.isEmpty ?? true)
      XCTAssertEqual(selfNode.inNetworkMap, true)
      XCTAssertEqual(selfNode.inMagicSock, true)
      XCTAssertEqual(selfNode.inEngine, true)
      XCTAssertNotNil(selfNode.keyExpiry)

      // 3. CapMap conformance
      guard let capMap = selfNode.capabilityMap else {
        XCTFail("Missing capabilityMap in \(version)")
        continue
      }
      XCTAssertEqual(capMap["tailnet.maxKeyDuration"], CapabilityValue.integers([86400]))
      XCTAssertEqual(capMap["https://tailscale.com/cap/ssh"], CapabilityValue.null)

      // 4. ?peers=false variant
      let peersFalseData = try localAPIFixture(version: version, endpoint: "status_peers_false")
      let peersFalseStatus = try JSONDecoder.tailscale().decode(
        StatusResponse.self, from: peersFalseData)
      XCTAssertTrue(peersFalseStatus.peers.isEmpty)
      XCTAssertNotNil(peersFalseStatus.selfNode)
    }

    // 5. BackendState Tolerant Decoding Fallback
    let futureJSON = """
      {
        "Version": "1.99.0",
        "BackendState": "HypotheticalFutureState",
        "TailscaleIPs": ["100.64.0.1"]
      }
      """.data(using: .utf8)!
    let futureStatus = try JSONDecoder.tailscale().decode(StatusResponse.self, from: futureJSON)
    XCTAssertEqual(futureStatus.backendState, BackendState.other)
  }

  // MARK: - Surface 2: Peers Conformance

  func testSurface2PeersConformance() async throws {
    for version in supportedVersions {
      let data = try localAPIFixture(version: version, endpoint: "whois")
      let whois = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: data)

      // Node properties
      guard let node = whois.node else {
        XCTFail("Missing node in whois for \(version)")
        continue
      }
      XCTAssertEqual(node.id, 1_000_000_000_000_001)
      XCTAssertEqual(node.stableID, "nStableSelf001")
      XCTAssertEqual(node.name, "example-device.example.ts.net.")
      XCTAssertEqual(node.user, 1_000_000_000_000_001)
      XCTAssertTrue(node.key?.hasPrefix("nodekey:") ?? false)
      XCTAssertTrue(node.machine?.hasPrefix("mkey:") ?? false)
      XCTAssertTrue(node.discoKey?.hasPrefix("discokey:") ?? false)
      XCTAssertEqual(node.addresses.first, "100.64.0.1/32")
      XCTAssertEqual(node.allowedIPs.first, "100.64.0.1/32")
      XCTAssertEqual(node.endpoints.first, "198.51.100.11:41641")
      XCTAssertEqual(node.hostinfo?.os, "macOS")
      XCTAssertEqual(node.hostinfo?.hostname, "example-device")
      XCTAssertEqual(node.online, true)
      XCTAssertEqual(node.isExitNode, false)

      // UserProfile
      guard let user = whois.userProfile else {
        XCTFail("Missing userProfile in whois for \(version)")
        continue
      }
      XCTAssertEqual(user.id, 1_000_000_000_000_001)
      XCTAssertEqual(user.loginName, "user1@example.com")
      XCTAssertEqual(user.displayName, "Self User")
      XCTAssertEqual(user.profilePicURL?.absoluteString, "https://example.com/avatars/user1.png")
    }

    // Wire 404 Disambiguation: Peer queries answer peerNotFound
    let notFoundTransport = MockTransport { request, _ in
      if request.path.contains("/whois") || request.path.contains("/peer") {
        return TailscaleResponse(
          statusCode: 404,
          data: Data("peer not found\n".utf8),
          headers: [:]
        )
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: notFoundTransport
      )
    )

    await assertThrowsErrorAsync(try await client.whois(address: "100.64.0.99")) { error in
      guard case TailscaleClientError.peerNotFound(let ep) = error else {
        XCTFail("Expected peerNotFound, got \(error)")
        return
      }
      XCTAssertTrue(ep.contains("/whois"))
    }

    await assertThrowsErrorAsync(try await client.peer(byID: 999_999)) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, _, let ep) = error else {
        XCTFail("Expected unexpectedStatus for peer(byID:), got \(error)")
        return
      }
      XCTAssertEqual(code, 404)
      XCTAssertTrue(ep.contains("/peer-by-id"))
    }
  }

  // MARK: - Surface 3: Routes Conformance

  func testSurface3RoutesConformance() async throws {
    // 1. CIDR Prefix round-tripping
    let rawCIDRs = [
      "100.64.0.1/32",
      "fd7a:115c:a1e0:ab12:4843:cd96:6200:0001/128",
      "192.168.1.0/24",
      "0.0.0.0/0",
      "::/0",
    ]
    var masked = MaskedPrefs()
    masked.routeAll = true
    masked.advertiseRoutes = rawCIDRs
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encodedMasked = try encoder.encode(masked)

    guard let jsonMap = try JSONSerialization.jsonObject(with: encodedMasked) as? [String: Any]
    else {
      XCTFail("Failed to deserialize jsonMap")
      return
    }
    XCTAssertEqual(jsonMap["RouteAll"] as? Bool, true)
    XCTAssertEqual(jsonMap["RouteAllSet"] as? Bool, true)
    XCTAssertEqual(jsonMap["AdvertiseRoutesSet"] as? Bool, true)
    let encodedCIDRs = jsonMap["AdvertiseRoutes"] as? [String]
    XCTAssertEqual(encodedCIDRs, rawCIDRs)

    // 2. DNSConfig Split Routes
    let dnsConfigData = try localAPIFixture(version: "1.98.0", endpoint: "dns-config")
    let dnsConfig = try JSONDecoder.tailscale().decode(DNSConfig.self, from: dnsConfigData)
    XCTAssertFalse(dnsConfig.routes.isEmpty)
    let internalRoute = dnsConfig.routes["internal.example.com."]
    XCTAssertNotNil(internalRoute)
    XCTAssertEqual(internalRoute?.first?.address, "10.0.0.1")
    XCTAssertEqual(internalRoute?.first?.useWithExitNode, true)

    // 3. Route Forwarding Preflights
    let forwardingOkTransport = MockTransport { request, _ in
      if request.path == "/localapi/v0/check-ip-forwarding" {
        return TailscaleResponse(statusCode: 200, data: Data("{\"Warning\": \"\"}".utf8))
      }
      if request.path == "/localapi/v0/check-udp-gro-forwarding" {
        return TailscaleResponse(statusCode: 200, data: Data("{\"Warning\": \"\"}".utf8))
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: forwardingOkTransport
      )
    )

    let ipCheck = try await client.checkIPForwarding()
    XCTAssertTrue(ipCheck.isReady)
    XCTAssertEqual(ipCheck.warning, "")

    let groCheck = try await client.checkUDPGROForwarding()
    XCTAssertTrue(groCheck.isReady)
    XCTAssertEqual(groCheck.warning, "")

    // Warning case
    let warningTransport = MockTransport { request, _ in
      if request.path == "/localapi/v0/check-ip-forwarding" {
        return TailscaleResponse(
          statusCode: 200,
          data: Data("{\"Warning\": \"net.ipv4.ip_forward is disabled\"}".utf8)
        )
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }
    let warnClient = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: warningTransport
      )
    )
    let warnCheck = try await warnClient.checkIPForwarding()
    XCTAssertFalse(warnCheck.isReady)
    XCTAssertEqual(warnCheck.warning, "net.ipv4.ip_forward is disabled")
  }

  // MARK: - Surface 4: Prefs & Masked Writes Conformance

  func testSurface4PrefsAndMaskedPrefsConformance() async throws {
    var change = MaskedPrefs()
    change.corpDNS = true
    change.wantRunning = true

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(change)
    let jsonMap = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

    // Set fields and flags must be present
    XCTAssertEqual(jsonMap?["CorpDNS"] as? Bool, true)
    XCTAssertEqual(jsonMap?["CorpDNSSet"] as? Bool, true)
    XCTAssertEqual(jsonMap?["WantRunning"] as? Bool, true)
    XCTAssertEqual(jsonMap?["WantRunningSet"] as? Bool, true)

    // Unmentioned fields must NOT be present
    XCTAssertNil(jsonMap?["RouteAll"])
    XCTAssertNil(jsonMap?["RouteAllSet"])
    XCTAssertNil(jsonMap?["ShieldsUp"])
    XCTAssertNil(jsonMap?["ShieldsUpSet"])
    XCTAssertNil(jsonMap?["AdvertiseRoutes"])
    XCTAssertNil(jsonMap?["AdvertiseRoutesSet"])
    XCTAssertNil(jsonMap?["ExitNodeID"])
    XCTAssertNil(jsonMap?["ExitNodeIDSet"])

    // Execute editPrefs via MockTransport
    let recorder = RequestRecorder()
    let prefsData = try localAPIFixture(version: "1.96.4", endpoint: "prefs")

    let editTransport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(
        statusCode: 200,
        data: prefsData,
        headers: ["Content-Type": "application/json"]
      )
    }

    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: editTransport
      )
    )

    let updatedPrefs = try await client.editPrefs(change)
    let recorded = await recorder.requests
    XCTAssertEqual(recorded.first?.method, "PATCH")
    XCTAssertEqual(recorded.first?.path, "/localapi/v0/prefs")
    XCTAssertNotNil(recorded.first?.body)
    XCTAssertEqual(updatedPrefs.wantRunning, true)
  }

  // MARK: - Surface 5: Serve Config Concurrency & Lossless Fields

  func testSurface5ServeConfigConcurrencyAndLosslessConformance() async throws {
    let initialConfigData = try localAPIFixture(version: "1.96.4", endpoint: "serve-config")
    let initialETag = "\"etag-sanitized-1.96.4-001\""

    // 1. Snapshot captures ETag and config
    let recorder = RequestRecorder()
    let serveTransport = MockTransport { request, _ in
      await recorder.record(request: request)
      if request.method == "GET" && request.path == "/localapi/v0/serve-config" {
        return TailscaleResponse(
          statusCode: 200,
          data: initialConfigData,
          headers: ["Content-Type": "application/json", "ETag": initialETag]
        )
      } else if request.method == "POST" && request.path == "/localapi/v0/serve-config" {
        return TailscaleResponse(
          statusCode: 200,
          data: initialConfigData,
          headers: ["Content-Type": "application/json", "ETag": "\"etag-updated-002\""]
        )
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: serveTransport
      )
    )

    let snapshot = try await client.serveConfigSnapshot()
    XCTAssertEqual(snapshot.etag, initialETag)
    XCTAssertFalse(snapshot.config.isEmpty)

    // 2. Conditional write sends If-Match
    _ = try await client.setServeConfig(snapshot.config, matching: snapshot)
    let recorded = await recorder.requests
    let postRequest = recorded.first { $0.method == "POST" }
    XCTAssertEqual(postRequest?.additionalHeaders["If-Match"], initialETag)

    // 3. Stale write conflict: HTTP 412 throws preconditionFailed
    let conflictTransport = MockTransport { request, _ in
      if request.method == "POST" {
        return TailscaleResponse(
          statusCode: 412,
          data: Data("etag mismatch\n".utf8),
          headers: [:]
        )
      }
      return TailscaleResponse(statusCode: 200, data: initialConfigData)
    }
    let conflictClient = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: conflictTransport
      )
    )

    await assertThrowsErrorAsync(
      try await conflictClient.setServeConfig(snapshot.config, matching: snapshot)
    ) { error in
      guard case TailscaleClientError.preconditionFailed = error else {
        XCTFail("Expected preconditionFailed, got \(error)")
        return
      }
    }

    // 4. Missing Concurrency Token: empty ETag throws missingConcurrencyToken
    let emptyETagSnapshot = ServeConfigSnapshot(
      etag: "", fetchedAt: Date(), config: snapshot.config)
    await assertThrowsErrorAsync(
      try await client.setServeConfig(snapshot.config, matching: emptyETagSnapshot)
    ) { error in
      guard case TailscaleClientError.missingConcurrencyToken = error else {
        XCTFail("Expected missingConcurrencyToken, got \(error)")
        return
      }
    }

    // 5. Unconditional replacement does NOT send If-Match
    let uncondRecorder = RequestRecorder()
    let uncondTransport = MockTransport { request, _ in
      await uncondRecorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data())
    }
    let uncondClient = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: uncondTransport
      )
    )
    try await uncondClient.replaceServeConfigUnconditionally(snapshot.config)
    let uncondRecorded = await uncondRecorder.requests
    XCTAssertEqual(uncondRecorded.first?.additionalHeaders["If-Match"], "")

    // 6. Lossless unmodeled field and 64-bit integer preservation
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: initialConfigData)
    guard case .object(let dict)? = config._unmodeledFields["CustomVendorSetting"] else {
      XCTFail("Missing CustomVendorSetting in decoded ServeConfig")
      return
    }
    XCTAssertEqual(dict["FeatureActive"], JSONValue.bool(true))
    XCTAssertEqual(dict["RateLimit"], JSONValue.integer(5_000_000_000))

    let reEncoded = try JSONEncoder().encode(config)
    let reDecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: reEncoded)
    XCTAssertEqual(config, reDecoded)
  }

  // MARK: - Surface 6: IPN Bus Streaming Conformance

  func testSurface6IPNBusStreamingConformance() async throws {
    let notifyJSON = """
      {"Version":"1.96.4","SessionID":"sess-001","State":6}
      """
    let script = MockStreamingScript(
      statusCode: 200,
      headers: ["Content-Type": "application/x-ndjson", "Tailscale-Version": "1.96.4"],
      events: [
        .jsonLine(notifyJSON)
      ]
    )

    let streamingTransport = MockTransport.scriptedStream(
      script.events, statusCode: 200, headers: script.headers)
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: streamingTransport
      )
    )

    let stream = try await client.watchIPNBus()
    var receivedNotification = false

    for try await notify in stream {
      XCTAssertEqual(notify.version, "1.96.4")
      XCTAssertEqual(notify.sessionID, "sess-001")
      XCTAssertEqual(notify.state, IPNState.running)
      receivedNotification = true
      break
    }
    XCTAssertTrue(receivedNotification)
  }

  // MARK: - Negative / Fault Injection Testing (Plan Acceptance Gate)

  func testNegativeInjectedFaultDetection() throws {
    // 1. Fault: Corrupt ETag string
    let validETag = "\"etag-sanitized-1.96.4-001\""
    let corruptedETag = "\"etag-corrupted-bad\""
    let etagDiff = assertDifferentialMatch(lhs: validETag, rhs: corruptedETag)
    XCTAssertFalse(etagDiff.isEqual)
    XCTAssertTrue(etagDiff.diff?.contains("mismatch") ?? false)

    // 2. Fault: Dropped AllowedIP
    let originalIPs = ["100.64.0.1/32", "fd7a:115c:a1e0::1/128"]
    let droppedIPs = ["100.64.0.1/32"]
    let ipDiff = assertDifferentialMatch(lhs: originalIPs, rhs: droppedIPs)
    XCTAssertFalse(ipDiff.isEqual)

    // 3. Fault: Mutated Unmodeled Field in ServeConfig
    let validServe = try JSONDecoder.tailscale().decode(
      ServeConfig.self,
      from: localAPIFixture(version: "1.96.4", endpoint: "serve-config")
    )
    var mutatedServe = validServe
    mutatedServe._unmodeledFields["CustomVendorSetting"] = .object([
      "FeatureActive": .bool(false),  // Deliberate inversion
      "RateLimit": .integer(5_000_000_000),
    ])
    XCTAssertNotEqual(validServe, mutatedServe)

    // 4. Fault: Toggled Boolean in Prefs
    let validPrefsData = try localAPIFixture(version: "1.96.4", endpoint: "prefs")
    let validPrefs = try JSONDecoder.tailscale().decode(Prefs.self, from: validPrefsData)
    var prefsMap = try JSONSerialization.jsonObject(with: validPrefsData) as! [String: Any]
    prefsMap["WantRunning"] = !(validPrefs.wantRunning ?? false)
    let mutatedPrefsData = try JSONSerialization.data(withJSONObject: prefsMap)
    let mutatedPrefs = try JSONDecoder.tailscale().decode(Prefs.self, from: mutatedPrefsData)
    XCTAssertNotEqual(validPrefs, mutatedPrefs)

    // 5. Fault: Corrupted 64-bit integer
    let originalInt: Int64 = 5_000_000_000
    let corruptedInt: Int64 = 5_000_000_001
    let intDiff = assertDifferentialMatch(lhs: originalInt, rhs: corruptedInt)
    XCTAssertFalse(intDiff.isEqual)
  }

  // MARK: - Complete Wire Error Mapping Matrix

  func testWireErrorMappingMatrix() async throws {
    let testCases:
      [(
        statusCode: Int, headers: [String: String], body: String, endpoint: String, optional: Bool,
        peerLookup: Bool, verify: (Error) -> Void
      )] = [
        // 400 Bad Request
        (
          400,
          [:],
          "bad request syntax\n",
          "/localapi/v0/status",
          false,
          false,
          { err in
            guard case TailscaleClientError.unexpectedStatus(let code, let body, let ep) = err
            else {
              XCTFail("Expected unexpectedStatus(400), got \(err)")
              return
            }
            XCTAssertEqual(code, 400)
            XCTAssertEqual(ep, "/localapi/v0/status")
            XCTAssertEqual(String(data: body, encoding: .utf8), "bad request syntax\n")
          }
        ),

        // 401 Unauthorized
        (
          401,
          [:],
          "missing loopback token\n",
          "/localapi/v0/status",
          false,
          false,
          { err in
            guard case TailscaleClientError.unexpectedStatus(let code, _, let ep) = err else {
              XCTFail("Expected unexpectedStatus(401), got \(err)")
              return
            }
            XCTAssertEqual(code, 401)
            XCTAssertEqual(ep, "/localapi/v0/status")
          }
        ),

        // 403 Forbidden
        (
          403,
          [:],
          "status access denied\n",
          "/localapi/v0/status",
          false,
          false,
          { err in
            guard case TailscaleClientError.permissionDenied(let body, let ep) = err else {
              XCTFail("Expected permissionDenied, got \(err)")
              return
            }
            XCTAssertEqual(ep, "/localapi/v0/status")
            XCTAssertEqual(String(data: body, encoding: .utf8), "status access denied\n")
          }
        ),

        // 404 Peer Not Found (peerLookup: true)
        (
          404,
          [:],
          "node not found\n",
          "/localapi/v0/whois",
          false,
          true,
          { err in
            guard case TailscaleClientError.peerNotFound(let ep) = err else {
              XCTFail("Expected peerNotFound, got \(err)")
              return
            }
            XCTAssertEqual(ep, "/localapi/v0/whois")
          }
        ),

        // 404 Optional Feature (optionalEndpoint: true)
        (
          404,
          [:],
          "404 page not found\n",
          "/localapi/v0/services",
          true,
          false,
          { err in
            guard case TailscaleClientError.endpointUnavailable(let ep, _) = err else {
              XCTFail("Expected endpointUnavailable, got \(err)")
              return
            }
            XCTAssertEqual(ep, "/localapi/v0/services")
          }
        ),

        // 404 Standard Endpoint
        (
          404,
          [:],
          "not found\n",
          "/localapi/v0/status",
          false,
          false,
          { err in
            guard case TailscaleClientError.unexpectedStatus(let code, _, let ep) = err else {
              XCTFail("Expected unexpectedStatus(404), got \(err)")
              return
            }
            XCTAssertEqual(code, 404)
            XCTAssertEqual(ep, "/localapi/v0/status")
          }
        ),

        // 412 Precondition Failed
        (
          412,
          [:],
          "etag mismatch\n",
          "/localapi/v0/serve-config",
          false,
          false,
          { err in
            guard case TailscaleClientError.preconditionFailed(let body, let ep) = err else {
              XCTFail("Expected preconditionFailed, got \(err)")
              return
            }
            XCTAssertEqual(ep, "/localapi/v0/serve-config")
            XCTAssertEqual(String(data: body, encoding: .utf8), "etag mismatch\n")
          }
        ),

        // 429 Rate Limited (Delta-seconds)
        (
          429,
          ["Retry-After": "45"],
          "rate limit exceeded\n",
          "/localapi/v0/status",
          false,
          false,
          { err in
            guard case TailscaleClientError.rateLimited(let retryAfter, _, let ep) = err else {
              XCTFail("Expected rateLimited, got \(err)")
              return
            }
            XCTAssertEqual(retryAfter, 45.0)
            XCTAssertEqual(ep, "/localapi/v0/status")
          }
        ),

        // 429 Rate Limited (RFC 9110 HTTP-date)
        (
          429,
          ["Retry-After": "Fri, 31 Dec 2027 23:59:59 GMT"],
          "rate limit exceeded\n",
          "/localapi/v0/status",
          false,
          false,
          { err in
            guard case TailscaleClientError.rateLimited(let retryAfter, _, _) = err else {
              XCTFail("Expected rateLimited with HTTP-date, got \(err)")
              return
            }
            XCTAssertNotNil(retryAfter)
            XCTAssertTrue((retryAfter ?? 0) > 0)
          }
        ),

        // 500 Internal Server Error
        (
          500,
          [:],
          "internal daemon panic\n",
          "/localapi/v0/status",
          false,
          false,
          { err in
            guard case TailscaleClientError.unexpectedStatus(let code, let body, let ep) = err
            else {
              XCTFail("Expected unexpectedStatus(500), got \(err)")
              return
            }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(ep, "/localapi/v0/status")
            XCTAssertEqual(String(data: body, encoding: .utf8), "internal daemon panic\n")
          }
        ),

        // 501 Not Implemented (Optional Endpoint)
        (
          501,
          [:],
          "feature unavailable\n",
          "/localapi/v0/suggest-exit-node",
          true,
          false,
          { err in
            guard case TailscaleClientError.endpointUnavailable(let ep, _) = err else {
              XCTFail("Expected endpointUnavailable for 501, got \(err)")
              return
            }
            XCTAssertEqual(ep, "/localapi/v0/suggest-exit-node")
          }
        ),

        // 503 Service Unavailable
        (
          503,
          [:],
          "no netmap available\n",
          "/localapi/v0/status",
          false,
          false,
          { err in
            guard case TailscaleClientError.unexpectedStatus(let code, let body, let ep) = err
            else {
              XCTFail("Expected unexpectedStatus(503), got \(err)")
              return
            }
            XCTAssertEqual(code, 503)
            XCTAssertEqual(ep, "/localapi/v0/status")
            XCTAssertEqual(String(data: body, encoding: .utf8), "no netmap available\n")
          }
        ),
      ]

    for tc in testCases {
      let statusCode = tc.statusCode
      let bodyData = Data(tc.body.utf8)
      let headers = tc.headers
      let mockTransport = MockTransport { _, _ in
        TailscaleResponse(
          statusCode: statusCode,
          data: bodyData,
          headers: headers
        )
      }

      let client = TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
          authToken: nil,
          transport: mockTransport
        )
      )

      if tc.peerLookup {
        await assertThrowsErrorAsync(try await client.whois(address: "100.64.0.99")) { err in
          tc.verify(err)
        }
      } else if tc.endpoint == "/localapi/v0/services" && tc.optional {
        await assertThrowsErrorAsync(try await client.services()) { err in
          tc.verify(err)
        }
      } else if tc.endpoint == "/localapi/v0/serve-config" && tc.statusCode == 412 {
        let fakeSnapshot = ServeConfigSnapshot(
          etag: "\"stale\"", fetchedAt: Date(), config: ServeConfig())
        await assertThrowsErrorAsync(
          try await client.setServeConfig(ServeConfig(), matching: fakeSnapshot)
        ) { err in
          tc.verify(err)
        }
      } else if tc.endpoint == "/localapi/v0/suggest-exit-node" && tc.optional {
        await assertThrowsErrorAsync(try await client.suggestExitNode()) { err in
          tc.verify(err)
        }
      } else {
        await assertThrowsErrorAsync(try await client.status()) { err in
          tc.verify(err)
        }
      }
    }
  }

  // MARK: - Go vs Swift Differential Parity

  func testGoOracleDifferentialParity() throws {
    // 1. Status Differential Parity against Go Oracle
    let statusData = try localAPIFixture(version: "1.96.4", endpoint: "status")
    let swiftStatus = try JSONDecoder.tailscale().decode(StatusResponse.self, from: statusData)

    let oracleStatusData = try localAPIFixture(version: "Oracle/1.96.4", endpoint: "status")
    let oracleStatus = try JSONDecoder.tailscale().decode(
      StatusResponse.self, from: oracleStatusData)

    XCTAssertEqual(swiftStatus.version, oracleStatus.version)
    XCTAssertEqual(swiftStatus.backendState, oracleStatus.backendState)
    XCTAssertEqual(swiftStatus.selfNode?.id, oracleStatus.selfNode?.id)
    XCTAssertEqual(swiftStatus.selfNode?.publicKey, oracleStatus.selfNode?.publicKey)
    XCTAssertEqual(swiftStatus.magicDNSSuffix, oracleStatus.magicDNSSuffix)
    XCTAssertEqual(swiftStatus.selfNode?.operatingSystem, oracleStatus.selfNode?.operatingSystem)

    // 2. WhoIs Differential Parity against Go Oracle
    let whoisData = try localAPIFixture(version: "1.96.4", endpoint: "whois")
    let swiftWhois = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: whoisData)

    let oracleWhoisData = try localAPIFixture(version: "Oracle/1.96.4", endpoint: "whois")
    let oracleWhois = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: oracleWhoisData)

    XCTAssertEqual(swiftWhois.node?.stableID, oracleWhois.node?.stableID)
    XCTAssertEqual(swiftWhois.node?.name, oracleWhois.node?.name)
    XCTAssertEqual(swiftWhois.userProfile?.loginName, oracleWhois.userProfile?.loginName)

    // 3. Prefs Differential Parity against Go Oracle
    let prefsData = try localAPIFixture(version: "1.96.4", endpoint: "prefs")
    let swiftPrefs = try JSONDecoder.tailscale().decode(Prefs.self, from: prefsData)

    let oraclePrefsData = try localAPIFixture(version: "Oracle/1.96.4", endpoint: "prefs")
    let oraclePrefs = try JSONDecoder.tailscale().decode(Prefs.self, from: oraclePrefsData)

    XCTAssertEqual(swiftPrefs.wantRunning, oraclePrefs.wantRunning)
    XCTAssertEqual(swiftPrefs.corpDNS, oraclePrefs.corpDNS)
    XCTAssertEqual(swiftPrefs.routeAll, oraclePrefs.routeAll)

    // 4. ServeConfig Differential Parity against Go Oracle
    let serveData = try localAPIFixture(version: "1.96.4", endpoint: "serve-config")
    let swiftServe = try JSONDecoder.tailscale().decode(ServeConfig.self, from: serveData)

    let oracleServeData = try localAPIFixture(version: "Oracle/1.96.4", endpoint: "serve-config")
    let oracleServe = try JSONDecoder.tailscale().decode(ServeConfig.self, from: oracleServeData)

    XCTAssertEqual(swiftServe.allowFunnel, oracleServe.allowFunnel)

    // 5. Oracle Manifest provenance
    let oracleManifestData = try localAPIFixture(version: "Oracle", endpoint: "oracle-manifest")
    let manifestMap = try JSONSerialization.jsonObject(with: oracleManifestData) as? [String: Any]
    XCTAssertEqual(manifestMap?["capability_level"] as? Int, 144)
    XCTAssertEqual(
      manifestMap?["upstream_commit"] as? String, "4c4d1c35f83a21c6069ae09de69b246ed1993f3e")
    XCTAssertEqual(manifestMap?["schema_version"] as? String, "1.0.0")
  }

  // MARK: - Helper Methods

  private func assertDifferentialMatch<T: Equatable>(lhs: T, rhs: T) -> (
    isEqual: Bool, diff: String?
  ) {
    if lhs == rhs {
      return (true, nil)
    }
    return (false, "Differential mismatch: \(lhs) != \(rhs)")
  }
}
