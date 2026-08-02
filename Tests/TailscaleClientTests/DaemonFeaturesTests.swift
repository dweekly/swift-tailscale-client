// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

final class DaemonFeaturesTests: XCTestCase {
  private func makeClient(
    _ transport: MockTransport, timeout: Duration? = .seconds(5)
  ) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://mock.local")!),
      authToken: nil,
      requestTimeout: timeout,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  func testDaemonFeaturesDecodesAndPosts() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(
        statusCode: 200,
        data: Data(#"{"Features":{"serve":true,"taildrop":false}}"#.utf8))
    }
    let client = makeClient(transport)

    let features = try await client.daemonFeatures()

    XCTAssertTrue(features.isEnabled("serve"))
    XCTAssertFalse(features.isEnabled("taildrop"))
    XCTAssertFalse(features.isEnabled("absent-feature"), "absent features report disabled")

    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/debug-optional-features")
  }

  func testDaemonFeaturesToleratesNullMap() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data(#"{"Features":null}"#.utf8))
    }
    let features = try await makeClient(transport).daemonFeatures()
    XCTAssertTrue(features.features.isEmpty)
  }

  func testDaemonFeatures404MapsToEndpointUnavailable() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("404 page not found".utf8))
    }
    let client = makeClient(transport)

    await assertThrowsErrorAsync(try await client.daemonFeatures()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(let endpoint, _) = clientError
      else {
        return XCTFail("expected endpointUnavailable, got \(error)")
      }
      XCTAssertEqual(endpoint, "/localapi/v0/debug-optional-features")
      XCTAssertNotNil(clientError.recoverySuggestion)
    }
  }

  func testRequestTimeoutThrowsTimeoutError() async {
    let transport = MockTransport { _, _ in
      try await Task.sleep(for: .seconds(30))
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = makeClient(transport, timeout: .milliseconds(50))

    await assertThrowsErrorAsync(try await client.status()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .timeout(let endpoint) = clientError
      else {
        return XCTFail("expected timeout, got \(error)")
      }
      XCTAssertEqual(endpoint, "/localapi/v0/status")
    }
  }

  func testNilTimeoutDisablesDeadline() async throws {
    let transport = MockTransport { _, _ in
      try await Task.sleep(for: .milliseconds(20))
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = makeClient(transport, timeout: nil)
    _ = try await client.status()
  }

  func testEnrichSetsHostCapabilityAndAuthHeaders() {
    let transport = URLSessionTailscaleTransport()
    let configuration = TailscaleClientConfiguration(
      endpoint: .loopback(port: 8080),
      authToken: "secret-token",
      capabilityVersion: 7)

    let enriched = transport.enrich(
      request: TailscaleRequest(path: "/localapi/v0/status"), configuration: configuration)

    XCTAssertEqual(enriched.additionalHeaders["Host"], "local-tailscaled.sock")
    XCTAssertEqual(enriched.additionalHeaders["Tailscale-Cap"], "7")
    let expectedAuth = "Basic \(Data(":secret-token".utf8).base64EncodedString())"
    XCTAssertEqual(enriched.additionalHeaders["Authorization"], expectedAuth)
  }

  func testEnrichOmitsAuthorizationWithoutToken() {
    let transport = URLSessionTailscaleTransport()
    let configuration = TailscaleClientConfiguration(
      endpoint: .loopback(port: 8080),
      authToken: nil)

    let enriched = transport.enrich(
      request: TailscaleRequest(path: "/localapi/v0/status"), configuration: configuration)

    XCTAssertNil(enriched.additionalHeaders["Authorization"])
    XCTAssertEqual(
      enriched.additionalHeaders["Tailscale-Cap"],
      String(TailscaleClientConfiguration.defaultCapabilityVersion))
  }
}
