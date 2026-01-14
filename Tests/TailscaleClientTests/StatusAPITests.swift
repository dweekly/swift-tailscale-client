// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class StatusAPITests: XCTestCase {
  func testStatusDecodesAndUsesTransport() async throws {
    let data = try fixture(named: "status-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, configuration in
      await recorder.record(request: request)
      XCTAssertEqual(configuration.capabilityVersion, 999)
      return TailscaleResponse(statusCode: 200, data: data)
    }

    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 999,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)
    let status = try await client.status()

    XCTAssertEqual(status.selfNode?.hostName, "example-device")
    let captured = await recorder.requests
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.path, "/localapi/v0/status")
    XCTAssertTrue(captured.first?.queryItems.isEmpty ?? false)
  }

  func testStatusIncludesQueryParameters() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }

    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)
    _ = try await client.status(query: StatusQuery(includePeers: false))

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.queryItems, [URLQueryItem(name: "peers", value: "false")])
  }

  func testStatusPropagatesTransportErrors() async {
    let transport = MockTransport { _, _ in
      throw TailscaleTransportError.networkFailure(underlying: URLError(.notConnectedToInternet))
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.status()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .transport(let transportError) = clientError,
        case .networkFailure(let underlying) = transportError,
        let urlError = underlying as? URLError
      else {
        XCTFail("Expected transport network failure, got \(error)")
        return
      }
      XCTAssertEqual(urlError.code, .notConnectedToInternet)
    }
  }

  func testStatusErrorsOnUnexpectedHTTPCode() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 500, data: Data("oops".utf8))
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.status()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(let code, let body, let endpoint) = clientError
      else {
        XCTFail("Expected unexpectedStatus error, got \(error)")
        return
      }
      XCTAssertEqual(code, 500)
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "oops")
      XCTAssertEqual(endpoint, "/localapi/v0/status")
    }
  }

  func testStatusErrorsOnDecodingFailures() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{\"invalid\":true".utf8))
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.status()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .decoding = clientError
      else {
        XCTFail("Expected decoding error, got \(error)")
        return
      }
    }
  }
}

// MARK: - Test Fixtures

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
    // Not used in these tests
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
