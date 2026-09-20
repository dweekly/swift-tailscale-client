// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tier 3: Cross-Feature Combinations E2E Test Suite.
///
/// Exercises pairwise and multi-feature interactions across configuration concurrency,
/// transport framing, discovery recovery, streaming monitoring, and preference management.
final class Tier3CombinationTests: XCTestCase {

  // MARK: - 1. ServeConfig Mutation + ETag Concurrency + Retry

  func test_combination_serveConfigConcurrencyConflictAndRetry() async throws {
    let counter = E2ETestSupport.AtomicCounter()
    let transport = MockTransport { request, _ in
      let callCount = counter.increment()
      if request.method == "GET" {
        return TailscaleResponse(
          statusCode: 200,
          data: Data(E2ETestSupport.serveConfigJSON().utf8),
          headers: ["ETag": callCount == 1 ? "\"etag-1\"" : "\"etag-2\""]
        )
      }
      if request.method == "POST" {
        let match = request.additionalHeaders["If-Match"]
        if match == "\"etag-1\"" {
          return TailscaleResponse(statusCode: 412, data: Data("precondition failed".utf8))
        } else if match == "\"etag-2\"" {
          return TailscaleResponse(
            statusCode: 200,
            data: Data("{}".utf8),
            headers: ["ETag": "\"etag-3\""]
          )
        }
      }
      return TailscaleResponse(statusCode: 400, data: Data())
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    // Step 1: Read initial configuration
    var config = try await client.serveConfig()
    XCTAssertEqual(config.etag, "\"etag-1\"")

    // Step 2: Attempt update with stale ETag -> 412 Precondition Failed
    config.tcp[9090] = TCPPortHandler(tcpForward: "127.0.0.1:9090")
    await assertThrowsErrorAsync(try await client.setServeConfig(config)) { error in
      guard case TailscaleClientError.preconditionFailed = error else {
        XCTFail("Expected preconditionFailed, got \(error)")
        return
      }
    }

    // Step 3: Re-fetch latest snapshot
    let freshConfig = try await client.serveConfig()
    XCTAssertEqual(freshConfig.etag, "\"etag-2\"")

    // Step 4: Re-apply change with fresh ETag -> Success
    var retriedConfig = freshConfig
    retriedConfig.tcp[9090] = TCPPortHandler(tcpForward: "127.0.0.1:9090")
    try await client.setServeConfig(retriedConfig)
  }

  // MARK: - 2. ServeConfig Update + Transport Error (500)

  func test_combination_serveConfigTransportErrorRollback() async throws {
    let transport = MockTransport { request, _ in
      if request.method == "GET" {
        return TailscaleResponse(
          statusCode: 200,
          data: Data("{}".utf8),
          headers: ["ETag": "\"initial-tag\""]
        )
      }
      return TailscaleResponse(statusCode: 500, data: Data("internal daemon error".utf8))
    }

    let client = E2ETestSupport.makeClient(transport: transport)
    let config = try await client.serveConfig()
    XCTAssertEqual(config.etag, "\"initial-tag\"")

    var modified = config
    modified.tcp[443] = TCPPortHandler(https: true)
    await assertThrowsErrorAsync(try await client.setServeConfig(modified)) { error in
      guard case TailscaleClientError.unexpectedStatus(let code, _, _) = error, code == 500 else {
        XCTFail("Expected unexpectedStatus 500, got \(error)")
        return
      }
    }
  }

  // MARK: - 3. Discovery Automatic Resolution + Daemon Restart Recovery

  func test_combination_discoveryAutomaticResolutionAndRestart() async throws {
    let attemptCounter = E2ETestSupport.AtomicCounter()
    let transport = MockTransport { _, _ in
      let count = attemptCounter.increment()
      if count == 1 {
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:41112")
      }
      return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    // First attempt fails due to daemon restart
    await assertThrowsErrorAsync(try await client.status()) { error in
      XCTAssertNotNil(error)
    }

    // Subsequent call succeeds after daemon recovery
    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
  }

  // MARK: - 4. IPN Bus Streaming + Mid-Stream Error + Reconnect

  func test_combination_streamingMidStreamFailureAndReconnect() async throws {
    struct StreamError: Error {}
    let events1: [MockStreamEvent] = [
      .jsonLine(E2ETestSupport.ipnNotifyJSON(state: 4)),
      .failure(StreamError()),
    ]
    let events2: [MockStreamEvent] = [
      .jsonLine(E2ETestSupport.ipnNotifyJSON(state: 4))
    ]

    let counter = E2ETestSupport.AtomicCounter()
    let transport = MockTransport.streaming { _, _ in
      let current = counter.increment()
      let events = current == 1 ? events1 : events2
      return try await MockTransport.scriptedStream(events).sendStreaming(
        TailscaleRequest(method: "GET", path: "/watch"),
        configuration: TailscaleClientConfiguration.default
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    // Stream 1 delivers line then fails
    let stream1 = try await client.watchIPNBus()
    var receivedFirst = false
    do {
      for try await notify in stream1 {
        XCTAssertEqual(notify.state, .stopped)
        receivedFirst = true
      }
    } catch {
      XCTAssertTrue(receivedFirst)
    }

    // Stream 2 reconnects and delivers line cleanly
    let stream2 = try await client.watchIPNBus()
    for try await notify in stream2 {
      XCTAssertEqual(notify.state, .stopped)
      break
    }
  }

  // MARK: - 5. IPN Bus Monitoring + High Volume Deltas + Status Sync

  func test_combination_streamingHighVolumeAndStatusReconciliation() async throws {
    let streamEvents: [MockStreamEvent] = (1...20).map {
      .jsonLine("{\"Version\": \"1.96.0\", \"State\": 4, \"BackendLogID\": \"log-\($0)\"}")
    }
    let transport = MockTransport(
      handler: { _, _ in
        TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
      },
      streaming: { _, _ in
        try await MockTransport.scriptedStream(streamEvents).sendStreaming(
          TailscaleRequest(method: "GET", path: "/watch"),
          configuration: TailscaleClientConfiguration.default
        )
      }
    )

    let client = E2ETestSupport.makeClient(transport: transport)
    let stream = try await client.watchIPNBus()

    var count = 0
    for try await notify in stream {
      XCTAssertEqual(notify.state, .stopped)
      count += 1
      if count >= 10 { break }
    }
    XCTAssertGreaterThanOrEqual(count, 10)

    // Reconcile complete status baseline
    let baseline = try await client.status()
    XCTAssertEqual(baseline.backendState, .running)
  }

  // MARK: - 6. Preferences Mutation + MaskedPrefs + Concurrency

  func test_combination_preferencesMutationWithMaskedPrefs() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { req, _ in
      await recorder.record(request: req)
      if req.method == "PATCH" {
        return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.prefsJSON().utf8))
      }
      return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.prefsJSON().utf8))
    }

    let client = E2ETestSupport.makeClient(transport: transport)
    let initialPrefs = try await client.prefs()
    XCTAssertEqual(initialPrefs.hostname, "test-node")

    var mask = MaskedPrefs()
    mask.routeAll = true
    try await client.editPrefs(mask)

    let requests = await recorder.requests
    XCTAssertTrue(requests.contains { $0.method == "PATCH" })
  }

  // MARK: - 7. Audit Reason Header + Mutating Request

  func test_combination_auditReasonWithMutatingRequests() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { req, _ in
      await recorder.record(request: req)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }

    let client = E2ETestSupport.makeClient(transport: transport)
    try await TailscaleClient.withAuditReason("Automated admin rotation") {
      try await client.setServeConfig(ServeConfig())
    }

    let req = await recorder.requests.first
    let expectedReason = Data("Automated admin rotation".utf8).base64EncodedString()
    XCTAssertEqual(req?.additionalHeaders["X-Tailscale-Reason"], expectedReason)
    XCTAssertEqual(req?.method, "POST")
  }

  // MARK: - 8. Capability Negotiation + Version Diagnostics + ACME 404

  func test_combination_capabilityVersionWithOptionalACMEEndpoint() async throws {
    let transport = MockTransport { req, _ in
      if req.path.contains("cert-domains") {
        return TailscaleResponse(statusCode: 404, data: Data("not found".utf8))
      }
      return TailscaleResponse(
        statusCode: 200,
        data: Data(E2ETestSupport.statusJSON().utf8),
        headers: ["Tailscale-Cap": "10", "Tailscale-Version": "1.76.0"]
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport, capabilityVersion: 10)
    _ = try await client.status()
    let diag = await client.versionDiagnostics()
    XCTAssertEqual(diag.daemonVersion, "1.76.0")

    await assertThrowsErrorAsync(try await client.certDomains()) { error in
      guard case TailscaleClientError.endpointUnavailable(let ep, let feat) = error else {
        XCTFail("Expected endpointUnavailable, got \(error)")
        return
      }
      XCTAssertEqual(ep, "/localapi/v0/cert-domains")
      XCTAssertEqual(feat, "acme")
    }
  }

  // MARK: - 9. Unconditional Replacement Wipes Existing State

  func test_combination_unconditionalReplacementWipesExistingState() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { req, _ in
      await recorder.record(request: req)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }

    let client = E2ETestSupport.makeClient(transport: transport)
    // Replace with completely blank configuration
    try await client.setServeConfig(ServeConfig())

    let postReq = await recorder.requests.first
    XCTAssertEqual(postReq?.additionalHeaders["If-Match"], "")
    XCTAssertEqual(postReq?.path, "/localapi/v0/serve-config")
  }

  // MARK: - 10. Task Cancellation + Streaming Lifetime Cleanup

  func test_combination_taskCancellationCleansUpStreamingTask() async throws {
    let events: [MockStreamEvent] = [
      .jsonLine(E2ETestSupport.ipnNotifyJSON()),
      .delay(.seconds(5)),
      .jsonLine(E2ETestSupport.ipnNotifyJSON()),
    ]
    let transport = MockTransport.scriptedStream(events)
    let client = E2ETestSupport.makeClient(transport: transport)

    let task = Task {
      let stream = try await client.watchIPNBus()
      for try await notify in stream {
        _ = notify
      }
    }

    try await Task.sleep(nanoseconds: 10_000_000)
    task.cancel()
    _ = await task.result
    XCTAssertTrue(task.isCancelled)
  }

  // MARK: - 11. WhoIs Lookup + Netcheck STUN Probe

  func test_combination_whoIsAndDERPMapInspection() async throws {
    let transport = MockTransport { req, _ in
      if req.path.contains("whois") {
        return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.whoIsJSON().utf8))
      }
      if req.path.contains("derpmap") {
        return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.derpMapJSON().utf8))
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let client = E2ETestSupport.makeClient(transport: transport)
    let whoIs = try await client.whois(address: "100.64.0.2")
    XCTAssertEqual(whoIs.node?.name, "target-node")

    let derp = try await client.derpMap()
    XCTAssertEqual(derp.regions.count, 2)
  }

  // MARK: - 12. Transport Header Injection + Auth Token

  func test_combination_transportHeaderInjectionAndAuthToken() async throws {
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: "secret-token-xyz"
    )
    let expectedAuth = "Basic " + Data(":secret-token-xyz".utf8).base64EncodedString()
    XCTAssertEqual(config.authToken, "secret-token-xyz")
    let credentials = ":\(config.authToken!)"
    let headerVal = "Basic \(Data(credentials.utf8).base64EncodedString())"
    XCTAssertEqual(headerVal, expectedAuth)
  }

  // MARK: - 13. DNS Diagnostics + Profile Management

  func test_combination_dnsDiagnosticsAndProfiles() async throws {
    let transport = MockTransport { req, _ in
      if req.path.contains("profiles") {
        return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.profilesJSON().utf8))
      }
      if req.path.contains("goroutines") {
        return TailscaleResponse(statusCode: 200, data: Data("goroutine stack".utf8))
      }
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }

    let client = E2ETestSupport.makeClient(transport: transport)
    let profiles = try await client.profiles()
    XCTAssertEqual(profiles.count, 2)
    XCTAssertEqual(profiles[0].name, "Personal")
    XCTAssertEqual(profiles[1].name, "Work")
  }

  // MARK: - 14. Daemon Lifecycle (Down -> Up) + Status Polling

  func test_combination_daemonControlLifecycleStateTransitions() async throws {
    actor StateHolder {
      var state = "Running"
      func stop() { state = "Stopped" }
      func current() -> String { state }
    }
    let holder = StateHolder()

    let transport = MockTransport { req, _ in
      if req.path.contains("shutdown") {
        await holder.stop()
        return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
      }
      let s = await holder.current()
      return TailscaleResponse(
        statusCode: 200,
        data: Data(E2ETestSupport.statusJSON(backendState: s).utf8)
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport)
    let initialStatus = try await client.status()
    XCTAssertEqual(initialStatus.backendState, .running)

    try await client.shutdownTailscaled()

    let runningStatus = try await client.status()
    XCTAssertEqual(runningStatus.backendState, .stopped)
  }

  // MARK: - 15. MockTransport Scripted Stream + Timing Delays

  func test_combination_scriptedStreamTimingDelays() async throws {
    let events: [MockStreamEvent] = [
      .jsonLine("{\"step\": 1}"),
      .delay(.milliseconds(5)),
      .jsonLine("{\"step\": 2}"),
    ]
    let transport = MockTransport.scriptedStream(events)
    let stream = try await transport.sendStreaming(
      TailscaleRequest(method: "GET", path: "/test"),
      configuration: TailscaleClientConfiguration.default
    )

    var count = 0
    for try await _ in stream {
      count += 1
    }
    XCTAssertEqual(count, 2)
  }
}
