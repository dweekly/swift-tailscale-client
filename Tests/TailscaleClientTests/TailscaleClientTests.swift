// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly


import XCTest

@testable import TailscaleClient

final class TailscaleClientTests: XCTestCase {
  func testDefaultConfigurationIsSendable() {
    _ = TailscaleClientConfiguration.default
  }

  func testStatusFailsGracefullyWhenSocketMissing() async {
    let configuration = TailscaleClientConfiguration(
      endpoint: .unixSocket(path: "/tmp/nonexistent-tailscale.sock"),
      authToken: nil,
      capabilityVersion: 1,
      transport: URLSessionTailscaleTransport())
    let client = TailscaleClient(configuration: configuration)

    await XCTAssertThrowsErrorAsync(try await client.status()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .transport(let transportError) = clientError,
        case .networkFailure(let underlying) = transportError
      else {
        XCTFail("Expected network failure, got: \(error)")
        return
      }
      let nsError = underlying as NSError
      XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
      XCTAssertEqual(nsError.code, Int(ENOENT))
    }
  }
}
