// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tests for the v0.6.0 network-diagnostics surfaces: `derpMap()`,
/// `suggestExitNode(forceProbe:)`, and `userMetrics()`.
final class NetworkDiagnosticsAPITests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - derpMap() Tests

  func testDERPMapDecodesAndUsesTransport() async throws {
    let data = try fixture(named: "derpmap-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }

    let client = makeClient(transport: transport)
    let map = try await client.derpMap()

    XCTAssertEqual(map.regions.count, 3)
    XCTAssertEqual(map.regions[2]?.regionCode, "sfo")

    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.method, "GET")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/derpmap")
  }

  func testDERPMapErrorsOnUnexpectedHTTPCode() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 500, data: Data("boom".utf8))
    }
    let client = makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.derpMap()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, _, let endpoint) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      XCTAssertEqual(code, 500)
      XCTAssertEqual(endpoint, "/localapi/v0/derpmap")
    }
  }

  // MARK: - suggestExitNode() Tests

  func testSuggestExitNodeUsesGETByDefault() async throws {
    let data = try fixture(named: "suggest-exit-node-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }

    let client = makeClient(transport: transport)
    let suggestion = try await client.suggestExitNode()

    XCTAssertEqual(suggestion.id, "nExitNodeStable123")
    XCTAssertEqual(suggestion.location?.countryCode, "US")

    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.method, "GET")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/suggest-exit-node")
    XCTAssertTrue(captured.first?.queryItems.isEmpty ?? false)
  }

  func testSuggestExitNodeForceProbePOSTsWithProbeQuery() async throws {
    let data = try fixture(named: "suggest-exit-node-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }

    let client = makeClient(transport: transport)
    _ = try await client.suggestExitNode(forceProbe: true)

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.queryItems, [URLQueryItem(name: "probe", value: "true")])
  }

  func testSuggestExitNodeMaps501ToEndpointUnavailable() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 501, data: Data("feature not available".utf8))
    }
    let client = makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.suggestExitNode()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(let endpoint, let feature) = clientError
      else {
        XCTFail("Expected endpointUnavailable error, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/suggest-exit-node")
      XCTAssertEqual(feature, "use-exit-node")
    }
  }

  func testSuggestExitNodeSurfacesDaemonErrors() async {
    // The daemon reports "no exit node candidates" as a plain HTTP error.
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 500, data: Data("no suggested exit node available".utf8))
    }
    let client = makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.suggestExitNode()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, let body, _) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      XCTAssertEqual(code, 500)
      XCTAssertEqual(String(data: body, encoding: .utf8), "no suggested exit node available")
    }
  }

  // MARK: - userMetrics() Tests

  func testUserMetricsReturnsRawTextAndUsesTransport() async throws {
    let body = """
      # TYPE tailscaled_inbound_bytes_total counter
      tailscaled_inbound_bytes_total{path="direct_ipv4"} 12345
      """
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data(body.utf8))
    }

    let client = makeClient(transport: transport)
    let metrics = try await client.userMetrics()

    XCTAssertTrue(metrics.contains("tailscaled_inbound_bytes_total"))

    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.method, "GET")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/usermetrics")
  }

  func testUserMetricsMaps404ToEndpointUnavailable() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("404 page not found".utf8))
    }
    let client = makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.userMetrics()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(let endpoint, _) = clientError
      else {
        XCTFail("Expected endpointUnavailable error, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/usermetrics")
    }
  }
}
