// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class TailscaleClientTests: XCTestCase {
  func testDefaultConfigurationIsSendable() {
    _ = TailscaleClientConfiguration.default
  }

  func testStatusFailsGracefullyWhenSocketMissing() async {
    let socketPath = "/tmp/nonexistent-tailscale.sock"
    let configuration = TailscaleClientConfiguration(
      endpoint: .unixSocket(path: socketPath),
      authToken: nil,
      capabilityVersion: 1,
      transport: URLSessionTailscaleTransport())
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.status()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .transport(let transportError) = clientError,
        case .socketNotFound(let path) = transportError
      else {
        XCTFail("Expected socketNotFound error, got: \(error)")
        return
      }
      XCTAssertEqual(path, socketPath)
      // Verify the error message is helpful
      XCTAssertTrue(
        transportError.description.contains("Unix socket not found"),
        "Error description should mention socket not found")
      XCTAssertTrue(
        transportError.recoverySuggestion?.contains("tailscaled") ?? false,
        "Recovery suggestion should mention tailscaled")
    }
  }
}
