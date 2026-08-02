// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tests for the v0.7.0 experimental namespace: `bugreport()`,
/// `goroutines()`, and `logtap()`.
final class ExperimentalAPITests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - bugreport

  func testBugreportPostsWithOptionsAndReturnsMarker() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(
        statusCode: 200, data: Data("BUG-1a2b3c4d5e6f7890abcdef-20260802190000-1\n".utf8))
    }
    let client = makeClient(transport: transport)
    let marker = try await client.experimental.bugreport(
      note: "repro attached", diagnose: true, record: true)

    XCTAssertEqual(marker, "BUG-1a2b3c4d5e6f7890abcdef-20260802190000-1")

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "POST")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/bugreport")
    XCTAssertEqual(
      captured.first?.queryItems,
      [
        URLQueryItem(name: "note", value: "repro attached"),
        URLQueryItem(name: "diagnose", value: "true"),
        URLQueryItem(name: "record", value: "true"),
      ])
  }

  func testBugreportDefaultsSendNoQuery() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("BUG-marker\n".utf8))
    }
    let client = makeClient(transport: transport)
    _ = try await client.experimental.bugreport()

    let captured = await recorder.requests
    XCTAssertTrue(captured.first?.queryItems.isEmpty ?? false)
  }

  func testBugreportMaps501ToEndpointUnavailable() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 501, data: Data("feature not available".utf8))
    }
    let client = makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.experimental.bugreport()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(let endpoint, let feature) = clientError
      else {
        XCTFail("Expected endpointUnavailable error, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/bugreport")
      XCTAssertEqual(feature, "debug")
    }
  }

  // MARK: - goroutines

  func testGoroutinesReturnsRawDump() async throws {
    let dump = "goroutine 1 [running]:\nmain.main()\n\t/go/src/tailscale.go:42 +0x1a\n"
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data(dump.utf8))
    }
    let client = makeClient(transport: transport)
    let result = try await client.experimental.goroutines()

    XCTAssertTrue(result.contains("goroutine 1 [running]"))
    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "GET")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/goroutines")
  }

  // MARK: - logtap

  func testLogtapStreamsEntriesAndToleratesNonJSON() async throws {
    let transport = MockTransport.scriptedStream([
      .jsonLine(#"{"text":"[logtap connected]\n"}"#),
      .jsonLine(#"{"text":"magicsock: derp home is 2\n"}"#),
      .line(Data("plain non-json line".utf8)),
    ])
    let client = makeClient(transport: transport)

    var entries: [LogtapEntry] = []
    for try await entry in try await client.experimental.logtap() {
      entries.append(entry)
    }

    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries.first?.text, "[logtap connected]\n")
    XCTAssertEqual(entries[1].text, "magicsock: derp home is 2\n")
    XCTAssertEqual(entries.last?.text, "plain non-json line")
  }

  func testLogtapSurfacesConnectionDrop() async throws {
    let transport = MockTransport.scriptedStream([
      .jsonLine(#"{"text":"one\n"}"#),
      .failure(TailscaleTransportError.networkFailure(underlying: POSIXError(.ECONNRESET))),
    ])
    let client = makeClient(transport: transport)

    var received = 0
    do {
      for try await _ in try await client.experimental.logtap() {
        received += 1
      }
      XCTFail("Expected the stream to end with an error")
    } catch {
      XCTAssertTrue(error is TailscaleClientError, "Expected mapped client error, got \(error)")
    }
    XCTAssertEqual(received, 1)
  }
}
