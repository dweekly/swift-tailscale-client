// SPDX-License-Identifier: MIT
// Recipe: Test a Tailscale integration using TailscaleClientMocks.
// Docs: Sources/TailscaleClient/TailscaleClient.docc/RecipeTesting.md

import TailscaleClient
import TailscaleClientMocks
import XCTest

final class MockedClientTests: XCTestCase {

  func testStatusAgainstAFixture() async throws {
    // MockTransport answers every request from your closure — no daemon.
    let fixture = Data(#"{"BackendState": "Running", "TailscaleIPs": ["100.64.0.1"]}"#.utf8)
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.path, "/localapi/v0/status")
      return TailscaleResponse(statusCode: 200, data: fixture)
    }
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://mock.local")!),
        authToken: nil,
        transport: transport))

    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
  }

  func testRecordingWritesForAssertions() async throws {
    // RequestRecorder (an actor) captures every request your code sends.
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://mock.local")!),
        authToken: nil,
        transport: transport))

    var change = MaskedPrefs()
    change.shieldsUp = true
    _ = try await client.editPrefs(change)

    let requests = await recorder.requests
    XCTAssertEqual(requests.first?.method, "PATCH")
    XCTAssertEqual(requests.first?.path, "/localapi/v0/prefs")
  }

  func testStreamingWithAScriptedBus() async throws {
    // Scripted streams exercise your IPN-bus handling deterministically.
    let transport = MockTransport.scriptedStream([
      .jsonLine(#"{"State": 6}"#),
      .jsonLine(#"{"State": 4}"#),
    ])
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://mock.local")!),
        authToken: nil,
        transport: transport))

    var states: [IPNState] = []
    for try await notify in try await client.watchIPNBus() {
      if let state = notify.state { states.append(state) }
    }
    XCTAssertEqual(states, [.running, .stopped])
  }

  func testExternalCustomTransportConformance() async throws {
    final class CustomConsumerTransport: TailscaleTransport, @unchecked Sendable {
      func send(
        _ request: TailscaleRequest,
        configuration: TailscaleClientConfiguration
      ) async throws -> TailscaleResponse {
        XCTAssertEqual(request.path, "/localapi/v0/status")
        return TailscaleResponse(
          statusCode: 200,
          data: Data(#"{"BackendState": "Running"}"#.utf8)
        )
      }

      func sendStreaming(
        _ request: TailscaleRequest,
        configuration: TailscaleClientConfiguration
      ) async throws -> StreamingResponse {
        StreamingResponse(
          statusCode: 200,
          headers: [:],
          body: AsyncThrowingStream { $0.finish() }
        )
      }
    }

    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://mock.local")!),
        authToken: nil,
        transport: CustomConsumerTransport()
      )
    )

    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
  }
}
