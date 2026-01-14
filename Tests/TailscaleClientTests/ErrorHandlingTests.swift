// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class ErrorHandlingTests: XCTestCase {

  // MARK: - TailscaleClientError Tests

  func testClientErrorBodyPreviewForUnexpectedStatus() {
    let shortBody = Data("short error message".utf8)
    let error = TailscaleClientError.unexpectedStatus(
      code: 500, body: shortBody, endpoint: "/test")

    XCTAssertEqual(error.bodyPreview, "short error message")
  }

  func testClientErrorBodyPreviewTruncatesLongBodies() {
    let longBody = Data(String(repeating: "x", count: 600).utf8)
    let error = TailscaleClientError.unexpectedStatus(code: 500, body: longBody, endpoint: "/test")

    let preview = error.bodyPreview
    XCTAssertNotNil(preview)
    XCTAssertTrue(preview!.contains("... (600 chars total)"))
    XCTAssertTrue(preview!.count < 600)
  }

  func testClientErrorBodyPreviewForBinaryData() {
    let binaryData = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
    let error = TailscaleClientError.unexpectedStatus(
      code: 500, body: binaryData, endpoint: "/test")

    XCTAssertEqual(error.bodyPreview, "<binary data: 5 bytes>")
  }

  func testClientErrorBodyPreviewNilForTransportError() {
    let error = TailscaleClientError.transport(.invalidURL)
    XCTAssertNil(error.bodyPreview)
  }

  func testClientErrorDescriptionForTransport() {
    let error = TailscaleClientError.transport(.socketNotFound(path: "/var/run/test.sock"))
    XCTAssertTrue(error.description.contains("Transport error"))
    XCTAssertTrue(error.description.contains("/var/run/test.sock"))
  }

  func testClientErrorDescriptionForUnexpectedStatus() {
    let testCases: [(Int, String)] = [
      (400, "Bad Request"),
      (401, "Unauthorized"),
      (403, "Forbidden"),
      (404, "Not Found"),
      (500, "Internal Server Error"),
      (502, "Bad Gateway"),
      (503, "Service Unavailable"),
    ]

    for (code, expectedMessage) in testCases {
      let error = TailscaleClientError.unexpectedStatus(
        code: code, body: Data(), endpoint: "/test")
      XCTAssertTrue(
        error.description.contains(expectedMessage),
        "Expected '\(expectedMessage)' in description for code \(code), got: \(error.description)")
      XCTAssertTrue(error.description.contains("/test"))
    }
  }

  func testClientErrorDescriptionForDecoding() {
    // keyNotFound
    let keyNotFoundContext = DecodingError.Context(
      codingPath: [CodingKeys.test], debugDescription: "Key not found")
    let keyNotFoundError = TailscaleClientError.decoding(
      .keyNotFound(CodingKeys.test, keyNotFoundContext), body: Data(), endpoint: "/test")
    XCTAssertTrue(keyNotFoundError.description.contains("missing key"))

    // typeMismatch
    let typeMismatchContext = DecodingError.Context(
      codingPath: [CodingKeys.test], debugDescription: "Type mismatch")
    let typeMismatchError = TailscaleClientError.decoding(
      .typeMismatch(String.self, typeMismatchContext), body: Data(), endpoint: "/test")
    XCTAssertTrue(typeMismatchError.description.contains("type mismatch"))

    // valueNotFound
    let valueNotFoundContext = DecodingError.Context(
      codingPath: [CodingKeys.test], debugDescription: "Value not found")
    let valueNotFoundError = TailscaleClientError.decoding(
      .valueNotFound(String.self, valueNotFoundContext), body: Data(), endpoint: "/test")
    XCTAssertTrue(valueNotFoundError.description.contains("null value"))

    // dataCorrupted
    let dataCorruptedContext = DecodingError.Context(
      codingPath: [CodingKeys.test], debugDescription: "Data corrupted")
    let dataCorruptedError = TailscaleClientError.decoding(
      .dataCorrupted(dataCorruptedContext), body: Data(), endpoint: "/test")
    XCTAssertTrue(dataCorruptedError.description.contains("corrupted data"))
  }

  func testClientErrorRecoverySuggestions() {
    // 401/403 - auth errors
    let authError = TailscaleClientError.unexpectedStatus(
      code: 401, body: Data(), endpoint: "/test")
    XCTAssertNotNil(authError.recoverySuggestion)
    XCTAssertTrue(authError.recoverySuggestion!.contains("auth token"))

    // 404 - not found
    let notFoundError = TailscaleClientError.unexpectedStatus(
      code: 404, body: Data(), endpoint: "/test")
    XCTAssertNotNil(notFoundError.recoverySuggestion)
    XCTAssertTrue(notFoundError.recoverySuggestion!.contains("Tailscale version"))

    // 5xx - server errors
    let serverError = TailscaleClientError.unexpectedStatus(
      code: 500, body: Data(), endpoint: "/test")
    XCTAssertNotNil(serverError.recoverySuggestion)
    XCTAssertTrue(serverError.recoverySuggestion!.contains("daemon"))

    // decoding error
    let decodingContext = DecodingError.Context(codingPath: [], debugDescription: "test")
    let decodingError = TailscaleClientError.decoding(
      .dataCorrupted(decodingContext), body: Data(), endpoint: "/test")
    XCTAssertNotNil(decodingError.recoverySuggestion)
    XCTAssertTrue(decodingError.recoverySuggestion!.contains("github.com"))

    // transport error passes through
    let transportError = TailscaleClientError.transport(.socketNotFound(path: "/test"))
    XCTAssertNotNil(transportError.recoverySuggestion)
  }

  func testClientErrorLocalizedError() {
    let error = TailscaleClientError.unexpectedStatus(
      code: 404, body: Data(), endpoint: "/test")
    XCTAssertEqual(error.errorDescription, error.description)
  }

  // MARK: - TailscaleTransportError Tests

  func testTransportErrorDescriptions() {
    let testCases: [(TailscaleTransportError, String)] = [
      (.unimplemented, "not implemented"),
      (.invalidURL, "Could not construct"),
      (.socketNotFound(path: "/var/run/test.sock"), "/var/run/test.sock"),
      (.connectionRefused(endpoint: "unix:/test"), "Connection refused"),
      (.malformedResponse(detail: "missing header"), "missing header"),
      (.networkFailure(underlying: URLError(.notConnectedToInternet)), "Network failure"),
    ]

    for (error, expectedSubstring) in testCases {
      XCTAssertTrue(
        error.description.lowercased().contains(expectedSubstring.lowercased()),
        "Expected '\(expectedSubstring)' in: \(error.description)")
    }
  }

  func testTransportErrorRecoverySuggestions() {
    let testCases: [(TailscaleTransportError, String)] = [
      (.unimplemented, "macOS/iOS"),
      (.invalidURL, "endpoint configuration"),
      (.socketNotFound(path: "/test"), "tailscale status"),
      (.connectionRefused(endpoint: "/test"), "Start the Tailscale"),
      (.malformedResponse(detail: "test"), "version mismatch"),
      (.networkFailure(underlying: URLError(.notConnectedToInternet)), "network connection"),
    ]

    for (error, expectedSubstring) in testCases {
      let suggestion = error.recoverySuggestion
      XCTAssertNotNil(suggestion, "Expected recovery suggestion for \(error)")
      XCTAssertTrue(
        suggestion!.contains(expectedSubstring),
        "Expected '\(expectedSubstring)' in: \(suggestion!)")
    }
  }

  func testTransportErrorLocalizedError() {
    let error = TailscaleTransportError.socketNotFound(path: "/test")
    XCTAssertEqual(error.errorDescription, error.description)
  }

  // MARK: - Error Propagation Tests

  func testDecodingErrorPropagation() async {
    // Test that various decoding errors are properly wrapped
    // Use invalid JSON that can't be parsed at all
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{not valid json".utf8))
    }
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    let client = TailscaleClient(configuration: configuration)

    await assertThrowsErrorAsync(try await client.status()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .decoding(let decodingError, let body, let endpoint) = clientError
      else {
        XCTFail("Expected decoding error, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/status")
      XCTAssertFalse(body.isEmpty)
      // Verify we got a dataCorrupted error (invalid JSON)
      if case .dataCorrupted = decodingError {
        // Expected
      } else {
        XCTFail("Expected dataCorrupted error, got \(decodingError)")
      }
    }
  }

  func testTransportErrorPropagation() async {
    let transport = MockTransport { _, _ in
      throw TailscaleTransportError.connectionRefused(endpoint: "test://endpoint")
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
        case .connectionRefused(let endpoint) = transportError
      else {
        XCTFail("Expected transport connectionRefused error, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "test://endpoint")
    }
  }

  func testNetworkFailureWrapping() async {
    let underlyingError = URLError(.timedOut)
    let transport = MockTransport { _, _ in
      throw TailscaleTransportError.networkFailure(underlying: underlyingError)
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
        XCTFail("Expected wrapped URLError, got \(error)")
        return
      }
      XCTAssertEqual(urlError.code, .timedOut)
    }
  }
}

// MARK: - Test Helpers

private enum CodingKeys: String, CodingKey {
  case test
}

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
