// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

#if os(macOS)
  /// Stale-vs-live selection tests for the App Store discovery fallback,
  /// using injected directories and an injected liveness probe so no real
  /// Group Containers (or TCC prompts) are involved.
  final class MacDiscoveryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
      tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mac-discovery-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
      try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeProof(port: UInt16, token: String, age: TimeInterval) throws {
      let url = tempDir.appendingPathComponent("sameuserproof-\(port)-\(token)")
      try Data().write(to: url)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    func testPrefersNewestCandidateWhenLive() throws {
      try writeProof(port: 1111, token: "older", age: 3600)
      try writeProof(port: 2222, token: "newer", age: 60)

      var info = MacClientInfo()
      info.directoriesOverride = [tempDir]
      info.probeOverride = { _, _ in true }  // everything answers

      let result = info.locateViaFilesystem()
      XCTAssertEqual(result?.port, 2222, "Newest live candidate should win")
      XCTAssertEqual(result?.token, "newer")
    }

    func testFallsBackToOlderLiveWhenNewestIsStale() throws {
      try writeProof(port: 1111, token: "older-live", age: 3600)
      try writeProof(port: 2222, token: "newer-stale", age: 60)

      var info = MacClientInfo()
      info.directoriesOverride = [tempDir]
      info.probeOverride = { port, _ in port == 1111 }  // only the old one answers

      let result = info.locateViaFilesystem()
      XCTAssertEqual(
        result?.port, 1111,
        "A stale newest candidate must be skipped in favor of an older live one")
    }

    func testReturnsNilWhenNothingAnswers() throws {
      try writeProof(port: 1111, token: "dead", age: 3600)

      var info = MacClientInfo()
      info.directoriesOverride = [tempDir]
      info.probeOverride = { _, _ in false }

      XCTAssertNil(info.locateViaFilesystem(), "Dead candidates must never be selected")
    }

    // MARK: - Standalone .pkg Discovery Tests

    func testStandaloneDiscoveryWithSymlinkAndTokenFile() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "token-hex-1234567890\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { port, token in
        port == 49275 && token == "token-hex-1234567890"
      }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.port, 49275)
      XCTAssertEqual(result?.token, "token-hex-1234567890")
      XCTAssertEqual(result?.source, ipnportURL.path)
    }

    func testStandaloneDiscoveryWithFallbackIpnportToken() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "51234")
      let tokenURL = tempDir.appendingPathComponent("ipnport.token")
      try "fallback-token-abc\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { port, token in
        port == 51234 && token == "fallback-token-abc"
      }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.port, 51234)
      XCTAssertEqual(result?.token, "fallback-token-abc")
    }

    func testStandaloneDiscoveryWithRegularFilePortFallback() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try "53412\n".write(to: ipnportURL, atomically: true, encoding: .utf8)
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-53412")
      try "regular-file-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { port, token in
        port == 53412 && token == "regular-file-token"
      }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.port, 53412)
      XCTAssertEqual(result?.token, "regular-file-token")
    }

    func testStandaloneDiscoverySkipsStalePortWhenProbeFails() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "token-hex-1234567890\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { _, _ in false }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNil(result, "Stale candidate that fails probe must return nil")

      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(inspection, .stopped(.loopback(host: "127.0.0.1", port: 49275)))
    }

    func testStandaloneDiscoveryRejectsEmptyToken() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "   \n".write(to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { _, _ in true }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNil(result, "Empty token must be rejected")

      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(inspection, .invalidCredentials(.loopback(host: "127.0.0.1", port: 49275)))
    }

    func testStandaloneDiscoveryReturnsNotInstalledWhenIpnportMissing() throws {
      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNil(result)

      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(inspection, .notInstalled)
    }

    func testStandaloneDiscoveryAsync() async throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "48000")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-48000")
      try "async-token-123\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { port, token in
        port == 48000 && token == "async-token-123"
      }

      let result = await info.locateStandaloneAsync(sharedDirectory: tempDir)
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.port, 48000)
      XCTAssertEqual(result?.token, "async-token-123")
    }
  }
#endif
