// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

final class AdversarialConformanceChallenger2Tests: XCTestCase {
  private let supportedVersions = ["1.76.0", "1.84.0", "1.96.4", "1.98.0"]

  // MARK: - 1. Full 4-Version Differential Parity (Raw Fixture vs Go Oracle)

  func testAllFourVersionsDifferentialParity() throws {
    for version in supportedVersions {
      // 1. Status Parity
      let rawStatusData = try localAPIFixture(version: version, endpoint: "status")
      let oracleStatusData = try localAPIFixture(version: "Oracle/\(version)", endpoint: "status")
      let swiftRawStatus = try JSONDecoder.tailscale().decode(
        StatusResponse.self, from: rawStatusData)
      let swiftOracleStatus = try JSONDecoder.tailscale().decode(
        StatusResponse.self, from: oracleStatusData)

      XCTAssertEqual(
        swiftRawStatus.version, swiftOracleStatus.version, "Status version mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.backendState, swiftOracleStatus.backendState,
        "BackendState mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.magicDNSSuffix, swiftOracleStatus.magicDNSSuffix,
        "MagicDNSSuffix mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.currentTailnet?.name, swiftOracleStatus.currentTailnet?.name,
        "CurrentTailnet name mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.currentTailnet?.magicDNSEnabled,
        swiftOracleStatus.currentTailnet?.magicDNSEnabled,
        "CurrentTailnet magicDNSEnabled mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.id, swiftOracleStatus.selfNode?.id,
        "Self node ID mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.publicKey, swiftOracleStatus.selfNode?.publicKey,
        "Self node public key mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.userID, swiftOracleStatus.selfNode?.userID,
        "Self node userID mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.operatingSystem, swiftOracleStatus.selfNode?.operatingSystem,
        "Self node OS mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.online, swiftOracleStatus.selfNode?.online,
        "Self node online mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.exitNode, swiftOracleStatus.selfNode?.exitNode,
        "Self node exitNode mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.exitNodeOption, swiftOracleStatus.selfNode?.exitNodeOption,
        "Self node exitNodeOption mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.allowedIPs, swiftOracleStatus.selfNode?.allowedIPs,
        "Self node allowedIPs mismatch on \(version)")
      XCTAssertEqual(
        swiftRawStatus.selfNode?.capabilityMap, swiftOracleStatus.selfNode?.capabilityMap,
        "Self node capabilityMap mismatch on \(version)")

      // 2. WhoIs Parity
      let rawWhoisData = try localAPIFixture(version: version, endpoint: "whois")
      let oracleWhoisData = try localAPIFixture(version: "Oracle/\(version)", endpoint: "whois")
      let swiftRawWhois = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: rawWhoisData)
      let swiftOracleWhois = try JSONDecoder.tailscale().decode(
        WhoIsResponse.self, from: oracleWhoisData)

      XCTAssertEqual(
        swiftRawWhois.node?.stableID, swiftOracleWhois.node?.stableID,
        "WhoIs node stableID mismatch on \(version)")
      XCTAssertEqual(
        swiftRawWhois.node?.name, swiftOracleWhois.node?.name,
        "WhoIs node name mismatch on \(version)")
      XCTAssertEqual(
        swiftRawWhois.node?.user, swiftOracleWhois.node?.user,
        "WhoIs node user mismatch on \(version)")
      XCTAssertEqual(
        swiftRawWhois.node?.key, swiftOracleWhois.node?.key, "WhoIs node key mismatch on \(version)"
      )
      XCTAssertEqual(
        swiftRawWhois.node?.allowedIPs, swiftOracleWhois.node?.allowedIPs,
        "WhoIs node allowedIPs mismatch on \(version)")
      XCTAssertEqual(
        swiftRawWhois.userProfile?.loginName, swiftOracleWhois.userProfile?.loginName,
        "WhoIs user login mismatch on \(version)")
      XCTAssertEqual(
        swiftRawWhois.userProfile?.id, swiftOracleWhois.userProfile?.id,
        "WhoIs user id mismatch on \(version)")

      // 3. Prefs Parity
      let rawPrefsData = try localAPIFixture(version: version, endpoint: "prefs")
      let oraclePrefsData = try localAPIFixture(version: "Oracle/\(version)", endpoint: "prefs")
      let swiftRawPrefs = try JSONDecoder.tailscale().decode(Prefs.self, from: rawPrefsData)
      let swiftOraclePrefs = try JSONDecoder.tailscale().decode(Prefs.self, from: oraclePrefsData)

      XCTAssertEqual(
        swiftRawPrefs.controlURL, swiftOraclePrefs.controlURL,
        "Prefs controlURL mismatch on \(version)")
      XCTAssertEqual(
        swiftRawPrefs.wantRunning, swiftOraclePrefs.wantRunning,
        "Prefs wantRunning mismatch on \(version)")
      XCTAssertEqual(
        swiftRawPrefs.corpDNS, swiftOraclePrefs.corpDNS, "Prefs corpDNS mismatch on \(version)")
      XCTAssertEqual(
        swiftRawPrefs.routeAll, swiftOraclePrefs.routeAll, "Prefs routeAll mismatch on \(version)")
      XCTAssertEqual(
        swiftRawPrefs.profileName, swiftOraclePrefs.profileName,
        "Prefs profileName mismatch on \(version)")

      // 4. ServeConfig Parity
      let rawServeData = try localAPIFixture(version: version, endpoint: "serve-config")
      let oracleServeData = try localAPIFixture(
        version: "Oracle/\(version)", endpoint: "serve-config")
      let swiftRawServe = try JSONDecoder.tailscale().decode(ServeConfig.self, from: rawServeData)
      let swiftOracleServe = try JSONDecoder.tailscale().decode(
        ServeConfig.self, from: oracleServeData)

      XCTAssertEqual(
        swiftRawServe.allowFunnel, swiftOracleServe.allowFunnel,
        "ServeConfig allowFunnel mismatch on \(version)")
      XCTAssertEqual(
        swiftRawServe.tcp.keys.sorted(), swiftOracleServe.tcp.keys.sorted(),
        "ServeConfig tcp keys mismatch on \(version)")
      XCTAssertEqual(
        swiftRawServe.web.keys.sorted(), swiftOracleServe.web.keys.sorted(),
        "ServeConfig web keys mismatch on \(version)")
      XCTAssertEqual(
        swiftRawServe._unmodeledFields, swiftOracleServe._unmodeledFields,
        "ServeConfig unmodeled fields mismatch on \(version)")
    }
  }

  // MARK: - 2. Adversarial Negative Fault Injection Stress

  func testAdversarialMutationsDetectedByDifferentialComparator() throws {
    // Mutation 1: Alter UserID
    let validStatusData = try localAPIFixture(version: "1.96.4", endpoint: "status")
    let originalStatus = try JSONDecoder.tailscale().decode(
      StatusResponse.self, from: validStatusData)
    var statusMap = try JSONSerialization.jsonObject(with: validStatusData) as! [String: Any]
    var selfNodeMap = statusMap["Self"] as! [String: Any]
    selfNodeMap["UserID"] = 1_000_000_000_000_999
    statusMap["Self"] = selfNodeMap
    let mutatedStatusData = try JSONSerialization.data(withJSONObject: statusMap)
    let mutatedStatus = try JSONDecoder.tailscale().decode(
      StatusResponse.self, from: mutatedStatusData)
    XCTAssertNotEqual(originalStatus.selfNode?.userID, mutatedStatus.selfNode?.userID)

    // Mutation 2: Change ExitNode flag in Status
    selfNodeMap["ExitNode"] = true
    statusMap["Self"] = selfNodeMap
    let exitMutatedData = try JSONSerialization.data(withJSONObject: statusMap)
    let exitMutatedStatus = try JSONDecoder.tailscale().decode(
      StatusResponse.self, from: exitMutatedData)
    XCTAssertNotEqual(originalStatus.selfNode?.exitNode, exitMutatedStatus.selfNode?.exitNode)

    // Mutation 3: Injecting extra adversarial route into AllowedIPs
    var allowedIPs = selfNodeMap["AllowedIPs"] as! [String]
    allowedIPs.append("10.0.0.0/8")
    selfNodeMap["AllowedIPs"] = allowedIPs
    statusMap["Self"] = selfNodeMap
    let routeMutatedData = try JSONSerialization.data(withJSONObject: statusMap)
    let routeMutatedStatus = try JSONDecoder.tailscale().decode(
      StatusResponse.self, from: routeMutatedData)
    XCTAssertNotEqual(originalStatus.selfNode?.allowedIPs, routeMutatedStatus.selfNode?.allowedIPs)

    // Mutation 4: Mutate CapMap in Status
    var capMap = selfNodeMap["CapMap"] as! [String: Any]
    capMap["https://tailscale.com/cap/adversarial"] = ["admin", "root"]
    selfNodeMap["CapMap"] = capMap
    statusMap["Self"] = selfNodeMap
    let capMutatedData = try JSONSerialization.data(withJSONObject: statusMap)
    let capMutatedStatus = try JSONDecoder.tailscale().decode(
      StatusResponse.self, from: capMutatedData)
    XCTAssertNotEqual(
      originalStatus.selfNode?.capabilityMap, capMutatedStatus.selfNode?.capabilityMap)

    // Mutation 5: Mutate MagicDNSEnabled in CurrentTailnet
    var currentTailnet = statusMap["CurrentTailnet"] as! [String: Any]
    currentTailnet["MagicDNSEnabled"] = false
    statusMap["CurrentTailnet"] = currentTailnet
    let dnsMutatedData = try JSONSerialization.data(withJSONObject: statusMap)
    let dnsMutatedStatus = try JSONDecoder.tailscale().decode(
      StatusResponse.self, from: dnsMutatedData)
    XCTAssertNotEqual(
      originalStatus.currentTailnet?.magicDNSEnabled,
      dnsMutatedStatus.currentTailnet?.magicDNSEnabled)

    // Mutation 6: Mutate node Key in WhoIs
    let validWhoisData = try localAPIFixture(version: "1.96.4", endpoint: "whois")
    let originalWhois = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: validWhoisData)
    var whoisMap = try JSONSerialization.jsonObject(with: validWhoisData) as! [String: Any]
    var nodeMap = whoisMap["Node"] as! [String: Any]
    nodeMap["Key"] = "nodekey:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    whoisMap["Node"] = nodeMap
    let mutatedWhoisData = try JSONSerialization.data(withJSONObject: whoisMap)
    let mutatedWhois = try JSONDecoder.tailscale().decode(
      WhoIsResponse.self, from: mutatedWhoisData)
    XCTAssertNotEqual(originalWhois.node?.key, mutatedWhois.node?.key)
  }

  // MARK: - 3. 64-bit Integer Precision & Huge Number Boundaries

  func test64BitIntegerPreservationInServeConfig() throws {
    let largeInts: [Int64] = [
      5_000_000_000,
      9_007_199_254_740_993,  // > 2^53 (cannot be represented precisely in Float64!)
      Int64.max - 1,
      Int64.max,
    ]

    for testVal in largeInts {
      let jsonString = """
        {
          "CustomVendorSetting": {
            "ExtremeRateLimit": \(testVal)
          }
        }
        """
      let data = Data(jsonString.utf8)
      let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: data)

      guard case .object(let dict)? = config._unmodeledFields["CustomVendorSetting"],
        case .integer(let decodedVal)? = dict["ExtremeRateLimit"]
      else {
        XCTFail("Failed to preserve large integer: \(testVal)")
        continue
      }

      XCTAssertEqual(
        decodedVal, testVal, "Loss of precision for 64-bit int: \(testVal) != \(decodedVal)")

      // Round-trip verification
      let encoded = try JSONEncoder().encode(config)
      let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)
      XCTAssertEqual(config, redecoded, "Round trip failed for \(testVal)")
    }
  }

  // MARK: - 4. Wire Error Matrix Boundary & Adversarial Cases

  func testWireErrorMatrixAdversarialVariations() async throws {
    // 1. 429 Rate Limited with Non-Numeric / Corrupted Retry-After
    let invalidRetryTransport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 429,
        data: Data("rate limit exceeded\n".utf8),
        headers: ["Retry-After": "garbage-not-a-number-or-date"]
      )
    }
    let client1 = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: invalidRetryTransport
      )
    )
    await assertThrowsErrorAsync(try await client1.status()) { err in
      guard case TailscaleClientError.rateLimited(let retryAfter, let body, let ep) = err else {
        XCTFail("Expected rateLimited, got \(err)")
        return
      }
      XCTAssertNil(retryAfter, "Invalid Retry-After should produce nil retryAfterSeconds")
      XCTAssertEqual(String(data: body, encoding: .utf8), "rate limit exceeded\n")
      XCTAssertEqual(ep, "/localapi/v0/status")
    }

    // 2. 429 Rate Limited with Empty Retry-After
    let emptyRetryTransport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 429,
        data: Data("rate limit\n".utf8),
        headers: ["Retry-After": ""]
      )
    }
    let client2 = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: emptyRetryTransport
      )
    )
    await assertThrowsErrorAsync(try await client2.status()) { err in
      guard case TailscaleClientError.rateLimited(let retryAfter, _, _) = err else {
        XCTFail("Expected rateLimited, got \(err)")
        return
      }
      XCTAssertNil(retryAfter)
    }

    // 3. 403 Forbidden with Empty Body
    let empty403Transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 403,
        data: Data(),
        headers: [:]
      )
    }
    let client3 = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: empty403Transport
      )
    )
    await assertThrowsErrorAsync(try await client3.status()) { err in
      guard case TailscaleClientError.permissionDenied(let body, _) = err else {
        XCTFail("Expected permissionDenied, got \(err)")
        return
      }
      XCTAssertTrue(body.isEmpty)
    }

    // 4. 412 Precondition Failed with Empty Body
    let empty412Transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 412,
        data: Data(),
        headers: [:]
      )
    }
    let client4 = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
        authToken: nil,
        transport: empty412Transport
      )
    )
    let fakeSnapshot = ServeConfigSnapshot(
      etag: "\"test\"",
      targetIdentifier: client4.targetIdentifier,
      fetchedAt: Date(),
      config: ServeConfig()
    )
    await assertThrowsErrorAsync(
      try await client4.setServeConfig(ServeConfig(), matching: fakeSnapshot)
    ) { err in
      guard case TailscaleClientError.preconditionFailed(let body, _) = err else {
        XCTFail("Expected preconditionFailed, got \(err)")
        return
      }
      XCTAssertTrue(body.isEmpty)
    }

    // 5. Unmapped HTTP status codes (418, 502, 504) map safely to unexpectedStatus
    for code in [418, 502, 504] {
      let unmappedTransport = MockTransport { _, _ in
        TailscaleResponse(
          statusCode: code,
          data: Data("upstream error \(code)\n".utf8),
          headers: [:]
        )
      }
      let unmappedClient = TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
          authToken: nil,
          transport: unmappedTransport
        )
      )
      await assertThrowsErrorAsync(try await unmappedClient.status()) { err in
        guard case TailscaleClientError.unexpectedStatus(let c, let body, let ep) = err else {
          XCTFail("Expected unexpectedStatus(\(code)), got \(err)")
          return
        }
        XCTAssertEqual(c, code)
        XCTAssertEqual(ep, "/localapi/v0/status")
        XCTAssertEqual(String(data: body, encoding: .utf8), "upstream error \(code)\n")
      }
    }
  }

  // MARK: - 5. MaskedPrefs Adversarial Field Coupling

  func testMaskedPrefsAdversarialFieldCoupling() throws {
    // When only one preference is set, only that preference and its *Set companion are encoded
    var prefs = MaskedPrefs()
    prefs.runSSH = true
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(prefs)
    let map = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    XCTAssertEqual(map["RunSSH"] as? Bool, true)
    XCTAssertEqual(map["RunSSHSet"] as? Bool, true)

    // Other Set flags must NOT be present
    let nonRunSSHFlags = [
      "RouteAllSet", "ExitNodeIDSet", "ExitNodeIPSet", "ExitNodeAllowLANAccessSet",
      "CorpDNSSet", "RunWebClientSet", "WantRunningSet", "LoggedOutSet",
      "ShieldsUpSet", "AdvertiseTagsSet", "HostnameSet", "ForceDaemonSet",
      "AdvertiseRoutesSet", "NoSNATSet", "NetfilterModeSet", "OperatorUserSet",
      "ProfileNameSet", "AutoUpdateSet", "AppConnectorSet", "PostureCheckingSet",
      "AdvertiseServicesSet", "AutoExitNodeSet",
    ]
    for flag in nonRunSSHFlags {
      XCTAssertNil(map[flag], "Unmodified flag \(flag) should be nil")
    }

    // Setting false must still produce *Set: true
    var falsePrefs = MaskedPrefs()
    falsePrefs.runSSH = false
    let falseData = try encoder.encode(falsePrefs)
    let falseMap = try JSONSerialization.jsonObject(with: falseData) as! [String: Any]
    XCTAssertEqual(falseMap["RunSSH"] as? Bool, false)
    XCTAssertEqual(falseMap["RunSSHSet"] as? Bool, true)
  }
}
