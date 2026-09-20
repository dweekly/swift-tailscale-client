// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import CryptoKit
import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

final class FixturePlaybackChallengerTests: XCTestCase {
  private let supportedVersions = ["1.76.0", "1.84.0", "1.96.4", "1.98.0"]

  // MARK: - Challenge 1: Cross-Version Go Oracle Parity

  func testAllVersionsGoOracleParity() throws {
    for version in supportedVersions {
      // 1. Status Parity
      let statusData = try localAPIFixture(version: version, endpoint: "status")
      let swiftStatus = try JSONDecoder.tailscale().decode(StatusResponse.self, from: statusData)

      let oracleStatusData = try localAPIFixture(version: "Oracle/\(version)", endpoint: "status")
      let oracleStatus = try JSONDecoder.tailscale().decode(
        StatusResponse.self, from: oracleStatusData)

      XCTAssertEqual(
        swiftStatus.version, oracleStatus.version,
        "Version mismatch in Status for \(version)")
      XCTAssertEqual(
        swiftStatus.backendState, oracleStatus.backendState,
        "BackendState mismatch for \(version)")
      XCTAssertEqual(
        swiftStatus.selfNode?.id, oracleStatus.selfNode?.id,
        "Self ID mismatch for \(version)")
      XCTAssertEqual(
        swiftStatus.selfNode?.publicKey, oracleStatus.selfNode?.publicKey,
        "PublicKey mismatch for \(version)")
      XCTAssertEqual(
        swiftStatus.magicDNSSuffix, oracleStatus.magicDNSSuffix,
        "MagicDNS mismatch for \(version)")
      XCTAssertEqual(
        swiftStatus.selfNode?.operatingSystem, oracleStatus.selfNode?.operatingSystem,
        "OS mismatch for \(version)")
      XCTAssertEqual(
        swiftStatus.selfNode?.tailscaleIPs, oracleStatus.selfNode?.tailscaleIPs,
        "Self IPs mismatch for \(version)")

      // 2. WhoIs Parity
      let whoisData = try localAPIFixture(version: version, endpoint: "whois")
      let swiftWhois = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: whoisData)

      let oracleWhoisData = try localAPIFixture(version: "Oracle/\(version)", endpoint: "whois")
      let oracleWhois = try JSONDecoder.tailscale().decode(
        WhoIsResponse.self, from: oracleWhoisData)

      XCTAssertEqual(
        swiftWhois.node?.stableID, oracleWhois.node?.stableID,
        "Whois Node ID mismatch for \(version)")
      XCTAssertEqual(
        swiftWhois.node?.name, oracleWhois.node?.name,
        "Whois Name mismatch for \(version)")
      XCTAssertEqual(
        swiftWhois.userProfile?.loginName, oracleWhois.userProfile?.loginName,
        "Whois LoginName mismatch for \(version)")
      XCTAssertEqual(
        swiftWhois.userProfile?.id, oracleWhois.userProfile?.id,
        "Whois UserID mismatch for \(version)")

      // 3. Prefs Parity
      let prefsData = try localAPIFixture(version: version, endpoint: "prefs")
      let swiftPrefs = try JSONDecoder.tailscale().decode(Prefs.self, from: prefsData)

      let oraclePrefsData = try localAPIFixture(version: "Oracle/\(version)", endpoint: "prefs")
      let oraclePrefs = try JSONDecoder.tailscale().decode(
        Prefs.self, from: oraclePrefsData)

      XCTAssertEqual(
        swiftPrefs.wantRunning, oraclePrefs.wantRunning,
        "Prefs wantRunning mismatch for \(version)")
      XCTAssertEqual(
        swiftPrefs.corpDNS, oraclePrefs.corpDNS,
        "Prefs corpDNS mismatch for \(version)")
      XCTAssertEqual(
        swiftPrefs.routeAll, oraclePrefs.routeAll,
        "Prefs routeAll mismatch for \(version)")

      // 4. ServeConfig Parity
      let serveData = try localAPIFixture(version: version, endpoint: "serve-config")
      let swiftServe = try JSONDecoder.tailscale().decode(ServeConfig.self, from: serveData)

      let oracleServeData = try localAPIFixture(
        version: "Oracle/\(version)", endpoint: "serve-config")
      let oracleServe = try JSONDecoder.tailscale().decode(
        ServeConfig.self, from: oracleServeData)

      XCTAssertEqual(
        swiftServe.allowFunnel, oracleServe.allowFunnel,
        "ServeConfig allowFunnel mismatch for \(version)")
      XCTAssertEqual(
        swiftServe.tcp[443]?.https, oracleServe.tcp[443]?.https,
        "ServeConfig TCP HTTPS mismatch for \(version)")

      // 5. DERPMap Parity
      let derpData = try localAPIFixture(version: version, endpoint: "derpmap")
      let swiftDERP = try JSONDecoder.tailscale().decode(DERPMap.self, from: derpData)

      let oracleDERPData = try localAPIFixture(version: "Oracle/\(version)", endpoint: "derpmap")
      let oracleDERP = try JSONDecoder.tailscale().decode(DERPMap.self, from: oracleDERPData)

      XCTAssertEqual(
        swiftDERP.regions.count, oracleDERP.regions.count,
        "DERPMap regions count mismatch for \(version)")
      XCTAssertEqual(
        swiftDERP.regions[1]?.regionCode, oracleDERP.regions[1]?.regionCode,
        "DERPMap regionCode mismatch for \(version)")

      // 6. CertDomains Parity
      let certData = try localAPIFixture(version: version, endpoint: "cert-domains")
      let swiftCerts = try JSONDecoder.tailscale().decode([String].self, from: certData)

      let oracleCertData = try localAPIFixture(
        version: "Oracle/\(version)", endpoint: "cert-domains")
      let oracleCerts = try JSONDecoder.tailscale().decode([String].self, from: oracleCertData)

      XCTAssertEqual(swiftCerts, oracleCerts, "CertDomains mismatch for \(version)")
    }
  }

  // MARK: - Challenge 2: Exhaustive Manifest-Driven Model Decoding Matrix

  func testAllEndpointsInManifestsDecodeToModels() throws {
    for version in supportedVersions {
      let manifestData = try localAPIManifest(version: version)
      guard let json = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
        let endpoints = json["endpoints"] as? [String: [String: Any]]
      else {
        XCTFail("Malformed manifest for \(version)")
        continue
      }

      for (epName, epInfo) in endpoints {
        guard let file = epInfo["file"] as? String,
          let modelName = epInfo["swift_model"] as? String
        else {
          continue
        }
        let baseName = file.replacingOccurrences(of: ".json", with: "")
        let data = try localAPIFixture(version: version, endpoint: baseName)

        switch modelName {
        case "StatusResponse":
          let model = try JSONDecoder.tailscale().decode(StatusResponse.self, from: data)
          XCTAssertEqual(model.version, version)
          XCTAssertNotNil(model.selfNode)
        case "WhoIsResponse":
          let model = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: data)
          XCTAssertNotNil(model.node)
        case "Prefs":
          let model = try JSONDecoder.tailscale().decode(Prefs.self, from: data)
          XCTAssertNotNil(model.wantRunning)
        case "ServeConfig":
          let model = try JSONDecoder.tailscale().decode(ServeConfig.self, from: data)
          XCTAssertFalse(model.isEmpty)
        case "DERPMap":
          let model = try JSONDecoder.tailscale().decode(DERPMap.self, from: data)
          XCTAssertFalse(model.regions.isEmpty)
        case "[String]":
          let model = try JSONDecoder.tailscale().decode([String].self, from: data)
          XCTAssertFalse(model.isEmpty)
        case "ExitNodeSuggestion":
          let model = try JSONDecoder.tailscale().decode(ExitNodeSuggestion.self, from: data)
          XCTAssertNotNil(model.id)
        case "DNSOSConfig":
          let model = try JSONDecoder.tailscale().decode(DNSOSConfig.self, from: data)
          XCTAssertFalse(model.nameservers.isEmpty)
        case "OptionalFeatures":
          let model = try JSONDecoder.tailscale().decode(OptionalFeatures.self, from: data)
          XCTAssertTrue(model.isEnabled("serve"))
        case "ProfilesResponse":
          let model = try JSONDecoder.tailscale().decode(ProfilesResponse.self, from: data)
          XCTAssertFalse(model.isEmpty)
        case "ServicesResponse":
          let model = try JSONDecoder.tailscale().decode(ServicesResponse.self, from: data)
          XCTAssertFalse(model.isEmpty)
        case "DNSConfig":
          let model = try JSONDecoder.tailscale().decode(DNSConfig.self, from: data)
          XCTAssertFalse(model.resolvers.isEmpty)
        default:
          XCTFail("Unknown swift_model in manifest: \(modelName) for \(epName)")
        }
      }
    }
  }

  // MARK: - Challenge 3: Boundary Integer Precision in ServeConfig

  func testServeConfigAdversarialIntegerBoundaries() throws {
    let baseData = try localAPIFixture(version: "1.98.0", endpoint: "serve-config")
    var jsonDict = try JSONSerialization.jsonObject(with: baseData) as! [String: Any]

    // Inject extreme integer boundaries into unmodeled fields
    jsonDict["AdversarialLimits"] = [
      "Int64Max": 9_223_372_036_854_775_807,
      "Int64Min": -9_223_372_036_854_775_808,
      "Int53Safe": 9_007_199_254_740_991,
      "Int32Max": 2_147_483_647,
    ]

    let mutatedData = try JSONSerialization.data(withJSONObject: jsonDict)
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: mutatedData)

    guard let adv = config._unmodeledFields["AdversarialLimits"],
      case .object(let dict) = adv
    else {
      XCTFail("Failed to preserve AdversarialLimits unmodeled field")
      return
    }

    XCTAssertEqual(dict["Int64Max"], JSONValue.integer(9_223_372_036_854_775_807))
    XCTAssertEqual(dict["Int64Min"], JSONValue.integer(-9_223_372_036_854_775_808))
    XCTAssertEqual(dict["Int53Safe"], JSONValue.integer(9_007_199_254_740_991))
    XCTAssertEqual(dict["Int32Max"], JSONValue.integer(2_147_483_647))

    // Round trip test
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let reencoded = try encoder.encode(config)
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: reencoded)
    XCTAssertEqual(config, redecoded, "Round-trip failed on extreme integer boundaries")
  }

  // MARK: - Challenge 4: TestSupport URL Resolution Isolation

  func testTestSupportLoadsVersionedServeConfigNotRootFixture() throws {
    // Verify that loading serve-config from 1.76.0 gets the versioned payload, not the root fixture
    let versionedData = try localAPIFixture(version: "1.76.0", endpoint: "serve-config")
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: versionedData)

    // In 1.76.0 versioned fixture, CustomVendorSetting is present
    XCTAssertNotNil(
      config._unmodeledFields["CustomVendorSetting"],
      "Loaded wrong serve-config fixture: CustomVendorSetting should be present in 1.76.0"
    )
    // In root Fixtures/serve-config.json, SomeFutureField is present and CustomVendorSetting is absent
    XCTAssertNil(
      config._unmodeledFields["SomeFutureField"],
      "Loaded root fixture instead of versioned fixture!"
    )
  }

  // MARK: - Challenge 5: Wire Framing Fault Detection in Conformance Models

  func testMalformedWirePayloadThrowsTypedError() {
    let truncatedJSON = Data("{\"Version\": \"1.98.0\", \"BackendState\": ".utf8)
    XCTAssertThrowsError(
      try JSONDecoder.tailscale().decode(StatusResponse.self, from: truncatedJSON)
    ) { error in
      XCTAssertTrue(
        error is DecodingError, "Expected DecodingError for truncated payload, got \(error)")
    }

    let typeMismatchJSON = Data("{\"Version\": 12345, \"BackendState\": \"Running\"}".utf8)
    XCTAssertThrowsError(
      try JSONDecoder.tailscale().decode(StatusResponse.self, from: typeMismatchJSON)
    ) { error in
      XCTAssertTrue(
        error is DecodingError, "Expected DecodingError for type mismatch, got \(error)")
    }
  }
}
