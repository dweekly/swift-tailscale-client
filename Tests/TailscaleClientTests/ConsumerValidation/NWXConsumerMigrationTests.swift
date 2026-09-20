// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

/// Consumer validation test suite simulating the Network Weather (NWX) macOS application.
///
/// NWX is a read-heavy monitoring and diagnostics application. This test suite validates
/// the 1.0 consumer integration path using strictly public APIs without `@testable import`.
final class NWXConsumerMigrationTests: XCTestCase {

  // MARK: - 1. Asynchronous Discovery

  func testAsynchronousDiscovery() async throws {
    // NWX discovers LocalAPI asynchronously at launch to avoid hitching the main actor
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "42111",
        "TAILSCALE_LOCALAPI_AUTHKEY": "nwx-test-token-sec",
      ],
      allowMacOSAppStoreDiscovery: false
    )

    let result = try await discovery.discoverAsync()
    XCTAssertEqual(result.endpoint, .loopback(host: "127.0.0.1", port: 42111))
    XCTAssertEqual(result.authToken, "nwx-test-token-sec")
  }

  // MARK: - 2. Initial Baseline Seeding (Status & Netcheck)

  func testInitialBaselineSeeding() async throws {
    let statusJSON = """
      {
        "Version": "1.80.0",
        "BackendState": "Running",
        "Self": {
          "ID": "nwx-self-node",
          "PublicKey": "key-self",
          "HostName": "nwx-macbook",
          "DNSName": "nwx-macbook.ts.net",
          "TailscaleIPs": ["100.64.0.1"]
        },
        "Peer": {
          "peer-node-1": {
            "ID": "peer-node-1",
            "PublicKey": "key-peer-1",
            "HostName": "office-router",
            "DNSName": "office-router.ts.net",
            "Online": true,
            "TailscaleIPs": ["100.64.0.2"]
          }
        }
      }
      """

    let derpMapJSON = """
      {
        "Regions": {}
      }
      """

    let transport = MockTransport { request, _ in
      if request.path == "/localapi/v0/status" {
        return TailscaleResponse(statusCode: 200, data: Data(statusJSON.utf8))
      }
      if request.path == "/localapi/v0/derpmap" {
        return TailscaleResponse(statusCode: 200, data: Data(derpMapJSON.utf8))
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // NWX fetches initial status and netcheck concurrently on startup
    async let statusTask = client.status()
    async let netcheckTask = client.netcheck()

    let (status, netcheck) = try await (statusTask, netcheckTask)

    XCTAssertEqual(status.version, "1.80.0")
    XCTAssertEqual(status.backendState, .running)
    XCTAssertEqual(status.selfNode?.hostName, "nwx-macbook")
    XCTAssertEqual(status.peers.count, 1)
    XCTAssertEqual(status.peers["peer-node-1"]?.hostName, "office-router")
    XCTAssertFalse(netcheck.udpWorking)
  }

  // MARK: - 3. Continuous IPN Bus Streaming with Bounds & Retry Policy

  func testContinuousIPNBusStreaming() async throws {
    let events: [MockStreamEvent] = [
      .jsonLine("{\"State\": 6, \"Version\": \"1.80.0\"}"),
      .jsonLine("{\"State\": 4}"),
    ]
    let transport = MockTransport.scriptedStream(events)

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let bounds = StreamBufferBounds(maxEventCount: 256, overflowStrategy: .reportGap)
    let stream = try await client.watchIPNBusEvents(
      options: [.initialState],
      retryPolicy: .none,
      bounds: bounds
    )

    var collectedEvents: [IPNBusEvent] = []
    for try await event in stream {
      collectedEvents.append(event)
      if collectedEvents.count == 3 { break }
    }

    // Sequence: .connected -> notify 1 (running) -> notify 2 (stopped)
    XCTAssertEqual(collectedEvents.count, 3)
    XCTAssertEqual(collectedEvents[0], .lifecycle(.connected))

    guard case .notification(let notify1) = collectedEvents[1] else {
      XCTFail("Expected first event to be notification, got \(collectedEvents[1])")
      return
    }
    XCTAssertEqual(notify1.state, .running)
    XCTAssertEqual(notify1.version, "1.80.0")

    guard case .notification(let notify2) = collectedEvents[2] else {
      XCTFail("Expected second event to be notification, got \(collectedEvents[2])")
      return
    }
    XCTAssertEqual(notify2.state, .stopped)
  }

  // MARK: - 4. Lifecycle Transitions (.connected, .disconnected, .retrying)

  func testLifecycleTransitionsEmitted() async throws {
    struct NetworkDropError: Error, Sendable {}

    let scripts: [MockStreamingScript] = [
      MockStreamingScript(
        statusCode: 200,
        headers: [:],
        events: [
          .jsonLine("{\"State\": 6}"),
          .failure(NetworkDropError()),
        ]
      ),
      MockStreamingScript(
        statusCode: 200,
        headers: [:],
        events: [
          .jsonLine("{\"State\": 6}")
        ]
      ),
    ]

    let transport = MockTransport.scriptedResponses(scripts)
    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let policy = StreamRetryPolicy(
      maxAttempts: 2,
      initialDelay: .milliseconds(10),
      maxDelay: .milliseconds(50),
      jitter: 0.0
    )

    let stream = try await client.watchIPNBusEvents(retryPolicy: policy)
    var lifecycleStates: [IPNBusLifecycle] = []

    for try await event in stream {
      if case .lifecycle(let lifecycle) = event {
        lifecycleStates.append(lifecycle)
      }
      if case .notification(let notify) = event, notify.state == .running,
        lifecycleStates.count >= 3
      {
        break
      }
    }

    // Check for presence of connected, retrying, and reconnected state gap
    let hasConnected = lifecycleStates.contains { $0 == .connected }
    let hasRetrying = lifecycleStates.contains {
      if case .retrying = $0 { return true }
      return false
    }
    let hasReconnectedGap = lifecycleStates.contains {
      if case .stateGap(let reason) = $0, reason == "reconnected" { return true }
      return false
    }

    XCTAssertTrue(hasConnected, "Must emit .connected lifecycle state")
    XCTAssertTrue(hasRetrying, "Must emit .retrying lifecycle state during transient drop")
    XCTAssertTrue(
      hasReconnectedGap, "Must emit .stateGap(reason: \"reconnected\") on stream recovery")
  }

  // MARK: - 5. State Gap Triggers Baseline Status Refresh

  func testStateGapTriggersBaselineStatusRefresh() async throws {
    actor NWXCacheState {
      var baselineRefreshCount = 0
      func recordRefresh() {
        baselineRefreshCount += 1
      }
      var count: Int { baselineRefreshCount }
    }

    let cache = NWXCacheState()

    // Scripted stream emits an unparseable line to trigger .stateGap(reason: "undecodable_line")
    let streamEvents: [MockStreamEvent] = [
      .line(Data("MALFORMED JSON UNPARSEABLE\n".utf8)),
      .jsonLine("{\"State\": 6}"),
    ]

    let statusResponseJSON = "{\"Version\": \"1.80.0\", \"BackendState\": \"Running\"}"

    let transport = MockTransport(
      handler: { request, _ in
        if request.path == "/localapi/v0/status" {
          return TailscaleResponse(statusCode: 200, data: Data(statusResponseJSON.utf8))
        }
        return TailscaleResponse(statusCode: 404, data: Data())
      },
      streaming: { _, _ in
        StreamingResponse(
          statusCode: 200,
          headers: [:],
          body: AsyncThrowingStream { continuation in
            for event in streamEvents {
              if case .line(let d) = event { continuation.yield(d) }
            }
            continuation.finish()
          }
        )
      }
    )

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let stream = try await client.watchIPNBusEvents(retryPolicy: .none)

    for try await event in stream {
      switch event {
      case .lifecycle(let lifecycle):
        if case .stateGap = lifecycle {
          // NWX consumer pattern: refresh baseline status to resync peer tables
          let refreshed = try await client.status()
          XCTAssertEqual(refreshed.backendState, .running)
          await cache.recordRefresh()
        }
      case .notification:
        break
      }
    }

    let refreshCount = await cache.count
    XCTAssertEqual(refreshCount, 1, "NWX must refresh baseline status upon receiving .stateGap")
  }

  // MARK: - 6. Daemon Restart Rediscovery via MockTransport

  func testDaemonRestartRediscovery() async throws {
    // Custom transport tracking port and auth token across daemon restart
    actor DaemonStateTracker: TailscaleTransport {
      var callCount = 0
      var usedTokens: [String?] = []

      func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
        async throws -> TailscaleResponse
      {
        callCount += 1
        usedTokens.append(configuration.authToken)

        if case .loopback(_, let port) = configuration.endpoint, port == 40001 {
          // Daemon was restarted; old port refuses connections
          throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:40001")
        }

        return TailscaleResponse(
          statusCode: 200,
          data: Data("{\"BackendState\": \"Running\", \"Version\": \"1.80.0\"}".utf8)
        )
      }

      func sendStreaming(
        _ request: TailscaleRequest,
        configuration: TailscaleClientConfiguration
      ) async throws -> StreamingResponse {
        throw TailscaleTransportError.unimplemented
      }

      var tokens: [String?] { usedTokens }
    }

    let tracker = DaemonStateTracker()

    // Discovery environment points to rotated port 40002 and refreshed token
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "40002",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-refreshed-post-restart",
      ]
    )

    // Initial configuration targets old port 40001 with .automatic discovery recovery
    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 40001),
      authToken: "token-stale-pre-restart",
      transport: tracker,
      endpointSource: .automatic(discovery)
    )
    let client = TailscaleClient(configuration: config)

    // Request should encounter ECONNREFUSED on port 40001, trigger rediscovery, and succeed on port 40002
    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
    XCTAssertEqual(status.version, "1.80.0")

    let tokens = await tracker.tokens
    XCTAssertEqual(tokens, ["token-stale-pre-restart", "token-refreshed-post-restart"])
    XCTAssertEqual(client.configuration.endpoint, .loopback(host: "127.0.0.1", port: 40002))
    XCTAssertEqual(client.configuration.authToken, "token-refreshed-post-restart")
  }
}
