// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly


import XCTest

@testable import TailscaleClient

#if canImport(Darwin)
  final class TailscaleClientIntegrationTests: XCTestCase {
    func testStatusAgainstLiveDaemon() async throws {
      guard ProcessInfo.processInfo.environment["TAILSCALE_INTEGRATION"] == "1" else {
        throw XCTSkip("Integration tests disabled. Set TAILSCALE_INTEGRATION=1 to enable.")
      }

      let client = TailscaleClient()
      let status = try await client.status()
      XCTAssertNotNil(
        status.selfNode, "Expected live status response to include self node information")
    }
  }
#endif
