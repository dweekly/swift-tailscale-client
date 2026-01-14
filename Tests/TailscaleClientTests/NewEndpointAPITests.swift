// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class NewEndpointAPITests: XCTestCase {

  // MARK: - whois() Tests

  func testWhoIsDecodesAndUsesTransport() async throws {
    let data = try fixture(named: "whois-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }

    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)
    let response = try await client.whois(address: "100.64.0.5")

    XCTAssertEqual(response.node?.id, 1_234_567_890_123_456)
    XCTAssertEqual(response.userProfile?.loginName, "admin@example.com")

    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.path, "/localapi/v0/whois")
    XCTAssertEqual(captured.first?.queryItems, [URLQueryItem(name: "addr", value: "100.64.0.5")])
  }

  func testWhoIsErrorsOnUnexpectedHTTPCode() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("not found".utf8))
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.whois(address: "100.64.0.99")) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, _, let endpoint) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      XCTAssertEqual(code, 404)
      XCTAssertEqual(endpoint, "/localapi/v0/whois")
    }
  }

  // MARK: - prefs() Tests

  func testPrefsDecodesAndUsesTransport() async throws {
    let data = try fixture(named: "prefs-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }

    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)
    let prefs = try await client.prefs()

    XCTAssertEqual(prefs.controlURL, "https://controlplane.tailscale.com")
    XCTAssertEqual(prefs.wantRunning, true)
    XCTAssertEqual(prefs.exitNodeID, "nExitNodeStable123")

    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.path, "/localapi/v0/prefs")
    XCTAssertTrue(captured.first?.queryItems.isEmpty ?? false)
  }

  func testPrefsErrorsOnUnexpectedHTTPCode() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 403, data: Data("forbidden".utf8))
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.prefs()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, _, let endpoint) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      XCTAssertEqual(code, 403)
      XCTAssertEqual(endpoint, "/localapi/v0/prefs")
    }
  }

  // MARK: - ping() Tests

  func testPingDecodesAndUsesTransport() async throws {
    let data = try fixture(named: "ping-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }

    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)
    let result = try await client.ping(ip: "100.64.0.5")

    XCTAssertEqual(result.ip, "100.64.0.5")
    XCTAssertEqual(result.nodeName, "example-peer")
    XCTAssertTrue(result.isSuccess)
    XCTAssertTrue(result.isDirect)

    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/ping")
    XCTAssertTrue(
      captured.first?.queryItems.contains(URLQueryItem(name: "ip", value: "100.64.0.5")) ?? false)
    XCTAssertTrue(
      captured.first?.queryItems.contains(URLQueryItem(name: "type", value: "disco")) ?? false)
  }

  func testPingWithTypeAndSize() async throws {
    let data = try fixture(named: "ping-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }

    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)
    _ = try await client.ping(ip: "100.64.0.5", type: .tsmp, size: 1024)

    let captured = await recorder.requests
    XCTAssertTrue(
      captured.first?.queryItems.contains(URLQueryItem(name: "type", value: "TSMP")) ?? false)
    XCTAssertTrue(
      captured.first?.queryItems.contains(URLQueryItem(name: "size", value: "1024")) ?? false)
  }

  func testPingErrorsOnUnexpectedHTTPCode() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 500, data: Data("internal error".utf8))
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.ping(ip: "100.64.0.5")) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, _, let endpoint) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      XCTAssertEqual(code, 500)
      XCTAssertEqual(endpoint, "/localapi/v0/ping")
    }
  }

  // MARK: - metrics() Tests

  func testMetricsReturnsRawText() async throws {
    let metricsText = """
      # HELP tailscale_health_messages Number of health messages
      # TYPE tailscale_health_messages gauge
      tailscale_health_messages 0
      # HELP tailscale_inbound_bytes_total Total inbound bytes
      # TYPE tailscale_inbound_bytes_total counter
      tailscale_inbound_bytes_total 123456
      """
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data(metricsText.utf8))
    }

    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)
    let result = try await client.metrics()

    XCTAssertTrue(result.contains("tailscale_health_messages"))
    XCTAssertTrue(result.contains("tailscale_inbound_bytes_total"))

    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.path, "/localapi/v0/metrics")
  }

  func testMetricsErrorsOnUnexpectedHTTPCode() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 503, data: Data("service unavailable".utf8))
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.metrics()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, _, let endpoint) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      XCTAssertEqual(code, 503)
      XCTAssertEqual(endpoint, "/localapi/v0/metrics")
    }
  }
}

// MARK: - Test Fixtures (reused pattern from StatusAPITests)

private struct MockTransport: TailscaleTransport {
  let handler:
    @Sendable (TailscaleRequest, TailscaleClientConfiguration) async throws -> TailscaleResponse

  func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration) async throws
    -> TailscaleResponse
  {
    try await handler(request, configuration)
  }

  func sendStreaming(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
    async throws -> AsyncThrowingStream<Data, Error>
  {
    throw TailscaleTransportError.unimplemented
  }
}

private actor RequestRecorder {
  private var storage: [TailscaleRequest] = []

  func record(request: TailscaleRequest) {
    storage.append(request)
  }

  var requests: [TailscaleRequest] {
    get async { storage }
  }
}
