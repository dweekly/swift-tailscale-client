// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

final class DiscoveryRecoveryTests: XCTestCase {
  // Mock transport actor to inspect calls and simulate responses
  actor ScriptedDiscoveryTransport: TailscaleTransport {
    var callCount = 0
    var observedTokens: [String?] = []
    var observedPorts: [UInt16] = []
    var sendHandler:
      (
        @Sendable (TailscaleRequest, TailscaleClientConfiguration) async throws -> TailscaleResponse
      )?

    func setHandler(
      _ handler:
        @escaping @Sendable (TailscaleRequest, TailscaleClientConfiguration) async throws ->
        TailscaleResponse
    ) {
      self.sendHandler = handler
    }

    func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration) async throws
      -> TailscaleResponse
    {
      callCount += 1
      observedTokens.append(configuration.authToken)
      if case .loopback(_, let port) = configuration.endpoint {
        observedPorts.append(port)
      }
      if let handler = sendHandler {
        return try await handler(request, configuration)
      }
      return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
    }

    func sendStreaming(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
      async throws -> StreamingResponse
    {
      callCount += 1
      return StreamingResponse(
        statusCode: 200,
        headers: [:],
        body: AsyncThrowingStream { continuation in
          continuation.finish()
        }
      )
    }
  }

  // MARK: - EndpointSource Tracking Tests

  func testEndpointSourceEnumCasesAndDescription() {
    let discovery = LocalAPIDiscovery(environment: ["TAILSCALE_LOCALAPI_AUTHKEY": "supersecret"])
    let autoSource = EndpointSource.automatic(discovery)
    let pinnedEndpoint = TailscaleEndpoint.loopback(host: "127.0.0.1", port: 41112)
    let pinnedSource = EndpointSource.pinned(pinnedEndpoint)

    XCTAssertEqual(autoSource.description, "EndpointSource.automatic")
    XCTAssertEqual(autoSource.debugDescription, "EndpointSource.automatic")
    XCTAssertFalse(
      autoSource.description.contains("supersecret"),
      "Token must not leak in EndpointSource description")

    XCTAssertEqual(pinnedSource.description, "EndpointSource.pinned(\(pinnedEndpoint))")
    XCTAssertEqual(pinnedSource.debugDescription, "EndpointSource.pinned(\(pinnedEndpoint))")

    XCTAssertNotEqual(autoSource, pinnedSource)
  }

  func testDefaultConfigurationHasAutomaticEndpointSource() {
    let config = TailscaleClientConfiguration.default
    guard case .automatic = config.endpointSource else {
      XCTFail("Default configuration must have .automatic endpointSource")
      return
    }
  }

  func testCustomInitDefaultsToPinnedEndpointSource() {
    let endpoint = TailscaleEndpoint.unixSocket(path: "/custom/tailscaled.sock")
    let config = TailscaleClientConfiguration(endpoint: endpoint, authToken: "tok")
    guard case .pinned(let ep) = config.endpointSource else {
      XCTFail("Custom init must default to .pinned endpointSource")
      return
    }
    XCTAssertEqual(ep, endpoint)
  }

  func testConfigurationCustomMirrorIncludesEndpointSourceAndRedactsToken() {
    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 1234),
      authToken: "confidential_token"
    )
    let mirror = config.customMirror
    var childrenMap: [String: Any] = [:]
    for child in mirror.children {
      if let label = child.label {
        childrenMap[label] = child.value
      }
    }
    XCTAssertEqual(childrenMap["authToken"] as? String, "<redacted>")
    XCTAssertNotNil(childrenMap["endpointSource"])
  }

  // MARK: - Dynamic Rediscovery and Recovery Tests

  func testAutoRecoveryOnLoopbackConnectionRefusal() async throws {
    let transport = ScriptedDiscoveryTransport()

    actor DiscoveryCounter {
      var count = 0
      func increment() { count += 1 }
    }
    let counter = DiscoveryCounter()

    // Configure discovery mock that switches port from 40001 to 40002
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "40002",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-new",
      ]
    )

    await transport.setHandler { request, config in
      await counter.increment()
      if case .loopback(_, let port) = config.endpoint, port == 40001 {
        // Old port refused connection
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:40001")
      }
      return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
    }

    let initialResult = LocalAPIDiscovery.Result(
      endpoint: .loopback(host: "127.0.0.1", port: 40001),
      authToken: "token-old",
      capabilityVersion: 144
    )
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: initialResult,
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // Unary call should recover and succeed
    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)

    let observedTokens = await transport.observedTokens
    XCTAssertEqual(observedTokens, ["token-old", "token-new"])

    let currentConfig = client.configuration
    XCTAssertEqual(currentConfig.endpoint, .loopback(host: "127.0.0.1", port: 40002))
    XCTAssertEqual(currentConfig.authToken, "token-new")
  }

  func testAutoRecoveryOnHTTP401Unauthorized() async throws {
    let transport = ScriptedDiscoveryTransport()

    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "40001",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-refreshed",
      ]
    )

    await transport.setHandler { request, config in
      if config.authToken == "token-stale" {
        return TailscaleResponse(statusCode: 401, data: Data("401 Unauthorized".utf8))
      }
      return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
    }

    let initialResult = LocalAPIDiscovery.Result(
      endpoint: .loopback(host: "127.0.0.1", port: 40001),
      authToken: "token-stale",
      capabilityVersion: 144
    )
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: initialResult,
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)

    let observedTokens = await transport.observedTokens
    XCTAssertEqual(observedTokens, ["token-stale", "token-refreshed"])
    XCTAssertEqual(client.configuration.authToken, "token-refreshed")
  }

  func testPinnedClientDoesNotAttemptRediscoveryOnFailure() async throws {
    let transport = ScriptedDiscoveryTransport()
    await transport.setHandler { _, _ in
      throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:40001")
    }

    let pinnedConfig = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 40001),
      authToken: "pinned-token",
      transport: transport,
      endpointSource: .pinned(.loopback(host: "127.0.0.1", port: 40001))
    )
    let client = TailscaleClient(configuration: pinnedConfig)

    do {
      _ = try await client.status()
      XCTFail("Expected connectionRefused error")
    } catch let error as TailscaleClientError {
      guard case .transport(.connectionRefused) = error else {
        XCTFail("Expected .transport(.connectionRefused), got \(error)")
        return
      }
    }

    let count = await transport.callCount
    XCTAssertEqual(count, 1, "Pinned client must never retry after connection refusal")
  }

  func testSingleFlightCoalescesConcurrentFailures() async throws {
    let transport = ScriptedDiscoveryTransport()

    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "40005",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-new",
      ]
    )

    await transport.setHandler { _, config in
      if config.authToken == "token-old" {
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:40004")
      }
      return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
    }

    let initialResult = LocalAPIDiscovery.Result(
      endpoint: .loopback(host: "127.0.0.1", port: 40004),
      authToken: "token-old",
      capabilityVersion: 144
    )
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: initialResult,
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // Launch 10 concurrent requests
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask {
          let res = try await client.status()
          XCTAssertEqual(res.backendState, .running)
        }
      }
      try await group.waitForAll()
    }

    // Client configuration was updated
    XCTAssertEqual(client.configuration.authToken, "token-new")
    XCTAssertEqual(client.configuration.endpoint, .loopback(host: "127.0.0.1", port: 40005))
  }

  func testMutationSafetyDoesNotReplayAmbiguousDisconnect() async throws {
    let transport = ScriptedDiscoveryTransport()

    // Ambiguous failure after connection (e.g. malformed response or connection reset)
    await transport.setHandler { _, _ in
      throw TailscaleTransportError.malformedResponse(detail: "Broken pipe during POST")
    }

    let discovery = LocalAPIDiscovery(
      environment: ["TAILSCALE_LOCALAPI_AUTHKEY": "token-new"]
    )
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 40001), authToken: "token-old",
        capabilityVersion: 144),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    do {
      try await client.setDNS(name: "example.com", value: "1.2.3.4")
      XCTFail("Expected malformedResponse error")
    } catch let error as TailscaleClientError {
      guard case .transport(.malformedResponse) = error else {
        XCTFail("Expected malformedResponse, got \(error)")
        return
      }
    }

    let count = await transport.callCount
    XCTAssertEqual(count, 1, "Ambiguous transport error on mutating request must never be replayed")
  }

  func testPreservesUserTransportAndTimeoutAcrossRediscovery() async throws {
    let transport = ScriptedDiscoveryTransport()
    let customTimeout = Duration.seconds(42)

    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "40009",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-refreshed",
      ]
    )

    await transport.setHandler { _, config in
      if config.authToken == "token-stale" {
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:40008")
      }
      return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
    }

    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 40008), authToken: "token-stale",
        capabilityVersion: 144),
      requestTimeout: customTimeout,
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    _ = try await client.status()

    let updated = client.configuration
    XCTAssertEqual(
      updated.requestTimeout, customTimeout,
      "Custom request timeout must be preserved across re-discovery")
    XCTAssertTrue(
      updated.transport is ScriptedDiscoveryTransport, "Injected transport must be preserved")
  }
}
