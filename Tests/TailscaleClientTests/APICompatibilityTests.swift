// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import TailscaleClient
import XCTest

/// External custom transport simulating a third-party networking library (e.g. AsyncHTTPClient or Cronet)
/// plugging directly into `TailscaleClient` via the public `TailscaleTransport` contract.
///
/// Notice this test deliberately avoids `@testable import TailscaleClient` to guarantee
/// that all exercised interfaces, initializers, and error cases are fully public.
final class ExternalCustomTransport: TailscaleTransport, @unchecked Sendable {
  typealias SendHandler =
    @Sendable (TailscaleRequest, TailscaleClientConfiguration) async throws -> TailscaleResponse
  typealias StreamHandler =
    @Sendable (TailscaleRequest, TailscaleClientConfiguration) async throws -> StreamingResponse

  let sendHandler: SendHandler
  let streamHandler: StreamHandler

  init(
    send: @escaping SendHandler = { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    },
    stream: @escaping StreamHandler = { _, _ in
      StreamingResponse(
        statusCode: 200,
        headers: ["Tailscale-Version": "1.80.0"],
        body: AsyncThrowingStream { continuation in continuation.finish() }
      )
    }
  ) {
    self.sendHandler = send
    self.streamHandler = stream
  }

  func send(
    _ request: TailscaleRequest,
    configuration: TailscaleClientConfiguration
  ) async throws -> TailscaleResponse {
    try await sendHandler(request, configuration)
  }

  func sendStreaming(
    _ request: TailscaleRequest,
    configuration: TailscaleClientConfiguration
  ) async throws -> StreamingResponse {
    try await streamHandler(request, configuration)
  }
}

private actor RequestCollector {
  var paths: [String] = []

  func record(path: String) {
    paths.append(path)
  }

  func contains(_ path: String) -> Bool {
    paths.contains(path)
  }

  var first: String? {
    paths.first
  }
}

final class APICompatibilityTests: XCTestCase {

  // MARK: - 1. Custom Transport Consumer & Injection

  func testCustomTransportUnaryExecution() async throws {
    let responseJSON = Data(#"{"BackendState": "Running", "Version": "1.80.0"}"#.utf8)
    let collector = RequestCollector()

    let transport = ExternalCustomTransport(
      send: { request, _ in
        await collector.record(path: request.path)
        return TailscaleResponse(statusCode: 200, data: responseJSON)
      }
    )

    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:8080")!),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
    XCTAssertEqual(status.version, "1.80.0")
    let recorded = await collector.first
    XCTAssertEqual(recorded, "/localapi/v0/status")
  }

  func testCustomTransportStreamingExecution() async throws {
    let lines = [
      Data("{\"State\": 6}\n".utf8),
      Data("{\"State\": 4}\n".utf8),
    ]

    let transport = ExternalCustomTransport(
      stream: { request, _ in
        XCTAssertEqual(request.path, "/localapi/v0/watch-ipn-bus")
        let stream = AsyncThrowingStream<Data, Error> { continuation in
          for line in lines {
            continuation.yield(line)
          }
          continuation.finish()
        }
        return StreamingResponse(
          statusCode: 200,
          headers: ["Tailscale-Version": "1.80.0"],
          body: stream
        )
      }
    )

    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:8080")!),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    var states: [IPNState] = []
    let eventStream = try await client.watchIPNBus()
    for try await notify in eventStream {
      if let state = notify.state {
        states.append(state)
      }
    }
    XCTAssertEqual(states, [.running, .stopped])
  }

  // MARK: - 2. ServeConfig Lossless Unmodeled Fields Encapsulation

  func testServeConfigUnmodeledFieldsEncapsulation() throws {
    var config = ServeConfig()
    config.unmodeledFields["RootCustom"] = .string("root-val")
    config.unmodeledFields["LargeInt"] = .integer(Int64.max)
    config.unmodeledFields["LargeUInt"] = .unsignedInteger(UInt64.max)

    var tcpHandler = TCPPortHandler(https: true)
    tcpHandler.unmodeledFields["TCPCustom"] = .bool(true)
    config.tcp[443] = tcpHandler

    var httpHandler = HTTPHandler(proxy: "http://localhost:8080")
    httpHandler.unmodeledFields["HTTPCustom"] = .array([.integer(1), .integer(2)])

    var webServer = WebServerConfig()
    webServer.handlers["/"] = httpHandler
    webServer.unmodeledFields["WebCustom"] = .string("web")
    config.web["example.com:443"] = webServer

    var service = ServiceConfig()
    service.unmodeledFields["ServiceCustom"] = .null
    config.services["svc"] = service

    // Assert that unmodeledFields public dictionary access works for all 5 structs
    XCTAssertEqual(config.unmodeledFields["RootCustom"], .string("root-val"))
    XCTAssertEqual(config.unmodeledFields["LargeInt"], .integer(Int64.max))
    XCTAssertEqual(config.unmodeledFields["LargeUInt"], .unsignedInteger(UInt64.max))
    XCTAssertEqual(config.tcp[443]?.unmodeledFields["TCPCustom"], .bool(true))
    XCTAssertEqual(config.web["example.com:443"]?.unmodeledFields["WebCustom"], .string("web"))
    XCTAssertEqual(
      config.web["example.com:443"]?.handlers["/"]?.unmodeledFields["HTTPCustom"],
      .array([.integer(1), .integer(2)]))
    XCTAssertEqual(config.services["svc"]?.unmodeledFields["ServiceCustom"], .null)
  }

  // MARK: - 3. NetworkInterfaceDiscovery.InterfaceInfo Public Initializer

  func testInterfaceInfoPublicInitializer() {
    let info = NetworkInterfaceDiscovery.InterfaceInfo(
      name: "utun99",
      address: "100.64.0.99",
      isIPv6: false,
      isUp: true,
      isRunning: true,
      isLoopback: false,
      isPointToPoint: true
    )
    XCTAssertEqual(info.name, "utun99")
    XCTAssertEqual(info.address, "100.64.0.99")
    XCTAssertFalse(info.isIPv6)
    XCTAssertTrue(info.isUp)
    XCTAssertTrue(info.isRunning)
    XCTAssertFalse(info.isLoopback)
    XCTAssertTrue(info.isPointToPoint)
  }

  // MARK: - 4. Canonical bugReport and Deprecated Alias

  func testExperimentalBugReportPublicAPI() async throws {
    let transport = ExternalCustomTransport(
      send: { request, _ in
        XCTAssertEqual(request.path, "/localapi/v0/bugreport")
        return TailscaleResponse(statusCode: 200, data: Data("BUG-MARKER-123\n".utf8))
      }
    )
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://127.0.0.1:8080")!),
        authToken: nil,
        transport: transport
      )
    )

    let markerCanonical = try await client.experimental.bugReport(
      note: "test-note", diagnose: true, record: false)
    XCTAssertEqual(markerCanonical, "BUG-MARKER-123")

    let markerAlias = try await client.experimental.bugreport(
      note: "test-note", diagnose: true, record: false)
    XCTAssertEqual(markerAlias, "BUG-MARKER-123")
  }

  // MARK: - 5. Profiles API Surface

  func testProfilesAPIPublicSurface() async throws {
    let profilesJSON = Data(#"[{"ID": "p1", "Name": "Profile 1", "Key": "k1"}]"#.utf8)
    let currentJSON = Data(#"{"ID": "p1", "Name": "Profile 1", "Key": "k1"}"#.utf8)
    let collector = RequestCollector()

    let transport = ExternalCustomTransport(
      send: { request, _ in
        await collector.record(path: request.path)
        if request.path == "/localapi/v0/profiles/" && request.method == "GET" {
          return TailscaleResponse(statusCode: 200, data: profilesJSON)
        }
        if request.path == "/localapi/v0/profiles/current" {
          return TailscaleResponse(statusCode: 200, data: currentJSON)
        }
        return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
      }
    )
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://127.0.0.1:8080")!),
        authToken: nil,
        transport: transport
      )
    )

    let list = try await client.profiles()
    XCTAssertEqual(list.count, 1)
    XCTAssertEqual(list.first?.id, "p1")

    let current = try await client.currentProfile()
    XCTAssertEqual(current.id, "p1")

    try await client.switchToEmptyProfile()
    try await client.switchProfile("p1")
    try await client.deleteProfile("p1")

    let hasProfiles = await collector.contains("/localapi/v0/profiles/")
    let hasCurrent = await collector.contains("/localapi/v0/profiles/current")
    let hasP1 = await collector.contains("/localapi/v0/profiles/p1")

    XCTAssertTrue(hasProfiles)
    XCTAssertTrue(hasCurrent)
    XCTAssertTrue(hasP1)
  }

  // MARK: - 6. Public Error Cases and Conformance

  func testPublicErrorCases() {
    let err1 = TailscaleClientError.missingConcurrencyToken
    let err2 = TailscaleClientError.streamOverflow
    let err3 = TailscaleClientError.discovery(LocalAPIDiscoveryError.notInstalled)
    let err4 = TailscaleClientError.preconditionFailed(body: Data(), endpoint: "serve-config")
    let err5 = TailscaleClientError.targetMismatch(expected: "targetA", actual: "targetB")

    XCTAssertNotNil(err1.errorDescription)
    XCTAssertNotNil(err2.errorDescription)
    XCTAssertNotNil(err3.errorDescription)
    XCTAssertNotNil(err4.errorDescription)
    XCTAssertNotNil(err5.errorDescription)
    XCTAssertNotNil(err5.recoverySuggestion)
    XCTAssertTrue(err5.errorDescription?.contains("targetA") == true)

    let sendableError: any Sendable = err5
    XCTAssertNotNil(sendableError)
  }

  // MARK: - 7. 1.0 Concurrency & Streaming Public Surfaces

  func testServeConfigSnapshotPublicAPI() {
    let snapshot = ServeConfigSnapshot(
      etag: "test-etag-123",
      targetIdentifier: "http://127.0.0.1:8080",
      config: ServeConfig()
    )
    XCTAssertEqual(snapshot.etag, "test-etag-123")
    XCTAssertEqual(snapshot.targetIdentifier, "http://127.0.0.1:8080")
    XCTAssertNotNil(snapshot.fetchedAt)
    XCTAssertEqual(snapshot.config, ServeConfig())

    let copy = snapshot
    XCTAssertEqual(snapshot, copy)
  }

  func testTargetIdentifierPublicSurface() {
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:8080")!),
      authToken: "secret"
    )
    XCTAssertEqual(config.targetIdentifier, "url(http://127.0.0.1:8080)")

    let client = TailscaleClient(configuration: config)
    XCTAssertEqual(client.targetIdentifier, "url(http://127.0.0.1:8080)")
  }

  func testStreamingBoundsAndPoliciesPublicAPI() {
    let bounds = StreamBufferBounds(
      maxEventCount: 512,
      maxByteCount: 8 * 1024 * 1024,
      overflowStrategy: .reportGap
    )
    XCTAssertEqual(bounds.maxEventCount, 512)
    XCTAssertEqual(bounds.maxByteCount, 8 * 1024 * 1024)
    XCTAssertEqual(bounds.overflowStrategy, .reportGap)

    XCTAssertEqual(StreamBufferBounds.default.maxEventCount, 256)
    XCTAssertEqual(StreamBufferBounds.throwing.overflowStrategy, .fail)

    let policy = StreamRetryPolicy(
      maxAttempts: 5,
      initialDelay: .milliseconds(100),
      maxDelay: .seconds(30),
      jitter: 0.2
    )
    XCTAssertEqual(policy.maxAttempts, 5)
    XCTAssertEqual(StreamRetryPolicy.none.maxAttempts, 0)
  }

  func testIPNBusEventAndLifecyclePublicAPI() {
    let connected = IPNBusEvent.lifecycle(.connected)
    let disconnected = IPNBusEvent.lifecycle(.disconnected(underlying: "peer reset"))
    let retrying = IPNBusEvent.lifecycle(.retrying(attempt: 2, delay: .seconds(1)))
    let gap = IPNBusEvent.lifecycle(.stateGap(reason: "buffer_overflow"))

    XCTAssertEqual(connected.lifecycle, .connected)
    XCTAssertEqual(disconnected.lifecycle, .disconnected(underlying: "peer reset"))
    XCTAssertEqual(retrying.lifecycle, .retrying(attempt: 2, delay: .seconds(1)))
    XCTAssertEqual(gap.lifecycle, .stateGap(reason: "buffer_overflow"))
    XCTAssertNil(connected.notification)

    XCTAssertEqual(connected.description, "IPNBusEvent.lifecycle(connected)")
  }
}

