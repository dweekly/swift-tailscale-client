// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import CryptoKit
import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

public typealias ServicesResponse = [String: ServiceDetails]
public typealias ProfilesResponse = [LoginProfile]

final class FixturePlaybackTests: XCTestCase {
  private let supportedVersions = ["1.76.0", "1.84.0", "1.96.4", "1.98.0"]

  // MARK: - 1. Manifest & File Integrity Tests

  func testMasterManifestIntegrity() throws {
    let manifestData = try localAPIManifest()
    let master = try JSONDecoder().decode(MasterManifest.self, from: manifestData)
    XCTAssertEqual(master.schemaVersion, "1.0.0")
    XCTAssertEqual(master.supportedFloor, "1.76.0")
    XCTAssertEqual(master.latestStable, "1.98.0")
    for version in supportedVersions {
      XCTAssertNotNil(master.versions[version], "Missing version \(version) in master manifest")
      XCTAssertFalse(master.versions[version]?.manifest.isEmpty ?? true)
    }
  }

  func testVersionManifestAndFileChecksums() throws {
    for version in supportedVersions {
      let versionManifestData = try localAPIManifest(version: version)
      let manifest = try JSONDecoder().decode(VersionManifest.self, from: versionManifestData)
      XCTAssertEqual(manifest.daemonVersion, version)

      for (_, ep) in manifest.endpoints {
        let baseName = ep.file.replacingOccurrences(of: ".json", with: "")
        let fileData = try localAPIFixture(version: version, endpoint: baseName)
        let hash = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, ep.sha256, "Checksum mismatch for \(version)/\(ep.file)")

        // Verify valid JSON
        XCTAssertNoThrow(
          try JSONSerialization.jsonObject(with: fileData),
          "Malformed JSON in \(version)/\(ep.file)"
        )
      }
    }
  }

  // MARK: - 2. Model Decoding Across Supported Versions

  func testStatusResponseDecoding() throws {
    for version in supportedVersions {
      let data = try localAPIFixture(version: version, endpoint: "status")
      let response = try JSONDecoder.tailscale().decode(StatusResponse.self, from: data)
      XCTAssertEqual(response.version, version)
      XCTAssertEqual(response.backendState, BackendState.running)
      XCTAssertFalse(response.tailscaleIPs.isEmpty)
      XCTAssertNotNil(response.selfNode)
      XCTAssertEqual(response.selfNode?.tailscaleIPs.first, "100.64.0.1")
      XCTAssertEqual(response.magicDNSSuffix, "example.ts.net")
      XCTAssertNotNil(response.currentTailnet)

      // Test ?peers=false variant
      let peersFalseData = try localAPIFixture(version: version, endpoint: "status_peers_false")
      let peersFalseResponse = try JSONDecoder.tailscale().decode(
        StatusResponse.self, from: peersFalseData)
      XCTAssertTrue(peersFalseResponse.peers.isEmpty)
      XCTAssertNotNil(peersFalseResponse.selfNode)
    }
  }

  func testWhoIsResponseDecoding() throws {
    for version in supportedVersions {
      let data = try localAPIFixture(version: version, endpoint: "whois")
      let response = try JSONDecoder.tailscale().decode(WhoIsResponse.self, from: data)
      XCTAssertNotNil(response.node)
      XCTAssertEqual(response.node?.addresses.first, "100.64.0.1/32")
      XCTAssertNotNil(response.userProfile)
      XCTAssertEqual(response.userProfile?.loginName, "user1@example.com")
      XCTAssertEqual(response.userProfile?.id, 1_000_000_000_000_001)
    }
  }

  func testPrefsResponseDecoding() throws {
    for version in supportedVersions {
      let data = try localAPIFixture(version: version, endpoint: "prefs")
      let prefs = try JSONDecoder.tailscale().decode(Prefs.self, from: data)
      XCTAssertEqual(prefs.controlURL, "https://controlplane.tailscale.com")
      XCTAssertEqual(prefs.wantRunning, true)
      XCTAssertEqual(prefs.corpDNS, true)
      XCTAssertEqual(prefs.profileName, "default")
    }
  }

  func testServeConfigDecodingAndRoundTripPreservation() throws {
    for version in supportedVersions {
      let data = try localAPIFixture(version: version, endpoint: "serve-config")
      let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: data)
      XCTAssertFalse(config.isEmpty)
      XCTAssertNotNil(config.tcp[443])
      XCTAssertEqual(config.tcp[443]?.https, true)

      // Verify unmodeled field preservation
      let custom = config._unmodeledFields["CustomVendorSetting"]
      XCTAssertNotNil(custom, "Missing CustomVendorSetting in \(version)")
      if case .object(let dict) = custom {
        XCTAssertEqual(dict["FeatureActive"], JSONValue.bool(true))
        XCTAssertEqual(dict["RateLimit"], JSONValue.integer(5_000_000_000))
      } else {
        XCTFail("CustomVendorSetting was not an object: \(String(describing: custom))")
      }

      // Lossless round-trip assertion
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let encoded = try encoder.encode(config)
      let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)
      XCTAssertEqual(config, redecoded, "ServeConfig round-trip lost fidelity on \(version)")
    }
  }

  func testDERPMapDecoding() throws {
    for version in supportedVersions {
      let data = try localAPIFixture(version: version, endpoint: "derpmap")
      let derpMap = try JSONDecoder.tailscale().decode(DERPMap.self, from: data)
      XCTAssertFalse(derpMap.regions.isEmpty)
      XCTAssertNotNil(derpMap.regions[1])
      XCTAssertEqual(derpMap.regions[1]?.regionCode, "nyc")
    }
  }

  func testCertDomainsDecoding() throws {
    for version in supportedVersions {
      let data = try localAPIFixture(version: version, endpoint: "cert-domains")
      let domains = try JSONDecoder.tailscale().decode([String].self, from: data)
      XCTAssertFalse(domains.isEmpty)
      XCTAssertTrue(domains.contains("example-device.example.ts.net"))
    }
  }

  func testIntermediateAndModernEndpointsDecoding() throws {
    // Endpoints present in 1.84.0, 1.96.4, 1.98.0
    for version in ["1.84.0", "1.96.4", "1.98.0"] {
      let exitData = try localAPIFixture(version: version, endpoint: "suggest-exit-node")
      let suggestion = try JSONDecoder.tailscale().decode(ExitNodeSuggestion.self, from: exitData)
      XCTAssertEqual(suggestion.id, "nExitNodeStable001")
      XCTAssertEqual(suggestion.location?.cityCode, "SFO")

      let dnsOSData = try localAPIFixture(version: version, endpoint: "dns-osconfig")
      let dnsOS = try JSONDecoder.tailscale().decode(DNSOSConfig.self, from: dnsOSData)
      XCTAssertFalse(dnsOS.nameservers.isEmpty)
      XCTAssertEqual(dnsOS.nameservers.first, "100.100.100.100")
    }

    // Endpoints present in 1.96.4, 1.98.0
    for version in ["1.96.4", "1.98.0"] {
      let dbgData = try localAPIFixture(version: version, endpoint: "debug-optional-features")
      let dbg = try JSONDecoder.tailscale().decode(OptionalFeatures.self, from: dbgData)
      XCTAssertTrue(dbg.isEnabled("serve"))
      XCTAssertTrue(dbg.isEnabled("acme"))

      let profData = try localAPIFixture(version: version, endpoint: "profiles")
      let profiles = try JSONDecoder.tailscale().decode(ProfilesResponse.self, from: profData)
      XCTAssertFalse(profiles.isEmpty)
      XCTAssertEqual(profiles.first?.id, "48d1")

      let svcData = try localAPIFixture(version: version, endpoint: "services")
      let services = try JSONDecoder.tailscale().decode(ServicesResponse.self, from: svcData)
      XCTAssertFalse(services.isEmpty)
      XCTAssertEqual(services["svc:metrics"]?.name, "svc:metrics")
      XCTAssertEqual(services["svc:metrics"]?.ports, ["tcp:9090"])
    }

    // Endpoints present in 1.98.0
    for version in ["1.98.0"] {
      let dnsCfgData = try localAPIFixture(version: version, endpoint: "dns-config")
      let dnsConfig = try JSONDecoder.tailscale().decode(DNSConfig.self, from: dnsCfgData)
      XCTAssertEqual(dnsConfig.resolvers.first?.address, "1.1.1.1")
      XCTAssertTrue(dnsConfig.proxied)
      XCTAssertFalse(dnsConfig.routes.isEmpty)
    }
  }

  // MARK: - 3. Client Facade Playback via MockTransport

  func testClientPlaybackWithMockTransport() async throws {
    for version in supportedVersions {
      let statusData = try localAPIFixture(version: version, endpoint: "status")
      let serveData = try localAPIFixture(version: version, endpoint: "serve-config")
      let whoisData = try localAPIFixture(version: version, endpoint: "whois")
      let prefsData = try localAPIFixture(version: version, endpoint: "prefs")
      let derpData = try localAPIFixture(version: version, endpoint: "derpmap")
      let expectedETag = "\"etag-sanitized-\(version)-001\""

      let mockTransport = MockTransport { request, _ in
        if request.path.hasPrefix("/localapi/v0/status") {
          return TailscaleResponse(
            statusCode: 200,
            data: statusData,
            headers: ["Content-Type": "application/json"]
          )
        } else if request.path.hasPrefix("/localapi/v0/serve-config") {
          return TailscaleResponse(
            statusCode: 200,
            data: serveData,
            headers: ["Content-Type": "application/json", "ETag": expectedETag]
          )
        } else if request.path.hasPrefix("/localapi/v0/whois") {
          return TailscaleResponse(
            statusCode: 200,
            data: whoisData,
            headers: ["Content-Type": "application/json"]
          )
        } else if request.path.hasPrefix("/localapi/v0/prefs") {
          return TailscaleResponse(
            statusCode: 200,
            data: prefsData,
            headers: ["Content-Type": "application/json"]
          )
        } else if request.path.hasPrefix("/localapi/v0/derpmap") {
          return TailscaleResponse(
            statusCode: 200,
            data: derpData,
            headers: ["Content-Type": "application/json"]
          )
        }
        return TailscaleResponse(statusCode: 404, data: Data())
      }

      let client = TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: .unixSocket(path: "/mock/tailscaled.sock"),
          authToken: nil,
          transport: mockTransport
        )
      )

      let status = try await client.status()
      XCTAssertEqual(status.version, version)
      XCTAssertEqual(status.backendState, BackendState.running)

      let snapshot = try await client.serveConfigSnapshot()
      XCTAssertEqual(snapshot.etag, expectedETag)
      XCTAssertFalse(snapshot.config.isEmpty)

      let whois = try await client.whois(address: "100.64.0.1")
      XCTAssertEqual(whois.node?.addresses.first, "100.64.0.1/32")

      let prefs = try await client.prefs()
      XCTAssertEqual(prefs.wantRunning, true)

      let derpMap = try await client.derpMap()
      XCTAssertFalse(derpMap.regions.isEmpty)
    }
  }

  // MARK: - 4. Leak Prevention & Sanitization Purity

  func testSanitizationPurityNoSecretsInFixtures() throws {
    let forbiddenTokens = [
      "tskey-auth-",
      "tskey-api-",
      "sameuserproof-",
      "privkey:",
      "BEGIN PRIVATE KEY",
    ]

    for version in supportedVersions {
      let manifestData = try localAPIManifest(version: version)
      let manifest = try JSONDecoder().decode(VersionManifest.self, from: manifestData)

      for (_, ep) in manifest.endpoints {
        let baseName = ep.file.replacingOccurrences(of: ".json", with: "")
        let data = try localAPIFixture(version: version, endpoint: baseName)
        let text = String(decoding: data, as: UTF8.self)

        for token in forbiddenTokens {
          if token.hasPrefix("tskey-") || token.hasPrefix("sameuserproof-") {
            let regex = try NSRegularExpression(pattern: "\(token)[a-zA-Z0-9_-]{12,}")
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for m in matches {
              let matchedStr = (text as NSString).substring(with: m.range)
              let isSynthetic =
                matchedStr.contains("synthetic-test")
                || matchedStr.contains("0000-0123456789abcdef")
              XCTAssertTrue(
                isSynthetic,
                "Potential unredacted token leak in \(version)/\(ep.file): \(matchedStr)"
              )
            }
          } else if token == "privkey:" {
            let regex = try NSRegularExpression(pattern: "privkey:[0-9a-fA-F]{64}")
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for m in matches {
              let matchedStr = (text as NSString).substring(with: m.range)
              XCTAssertTrue(
                matchedStr
                  == "privkey:0000000000000000000000000000000000000000000000000000000000000000",
                "Non-zero private key found in \(version)/\(ep.file): \(matchedStr)"
              )
            }
          } else {
            XCTAssertFalse(
              text.contains(token),
              "Forbidden pattern '\(token)' found in \(version)/\(ep.file)"
            )
          }
        }
      }
    }
  }
}

// MARK: - Supporting Manifest Decodables

private struct MasterManifest: Codable {
  let schemaVersion: String
  let supportedFloor: String
  let latestStable: String
  let mainlineVersions: [String]
  let versions: [String: MasterVersionEntry]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case supportedFloor = "supported_floor"
    case latestStable = "latest_stable"
    case mainlineVersions = "mainline_versions"
    case versions
  }
}

private struct MasterVersionEntry: Codable {
  let path: String
  let manifest: String
  let endpointCount: Int
  let tier: String

  enum CodingKeys: String, CodingKey {
    case path, manifest
    case endpointCount = "endpoint_count"
    case tier
  }
}

private struct VersionManifest: Codable {
  let schemaVersion: String
  let daemonVersion: String
  let endpoints: [String: EndpointEntry]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case daemonVersion = "daemon_version"
    case endpoints
  }
}

private struct EndpointEntry: Codable {
  let file: String
  let path: String
  let method: String
  let httpStatus: Int
  let headers: [String: String]?
  let sha256: String
  let swiftModel: String?

  enum CodingKeys: String, CodingKey {
    case file, path, method
    case httpStatus = "http_status"
    case headers, sha256
    case swiftModel = "swift_model"
  }
}
