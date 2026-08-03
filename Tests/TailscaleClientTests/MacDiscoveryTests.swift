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
  }
#endif
