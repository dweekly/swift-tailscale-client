// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

#if os(macOS)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Empirical challenger test suite for Milestone 2 Week 4 (PR 08 & PR 09).
///
/// Rigorously verifies:
/// 1. Concurrency stampede: 120+ concurrent requests hitting a restarting daemon
///    coalesce into exactly 1 re-discovery operation and all succeed.
/// 2. Mutation safety: Ambiguous transport disconnects (EOF, reset, malformed response)
///    during mutating requests (POST) must NEVER be replayed (zero duplicate executions).
///    Connect-stage disconnects replay at most once.
/// 3. Pinned immutability: `.pinned` targets never perform dynamic re-discovery
///    under repeated unary or streaming failures.
/// 4. Nonisolated thread safety: Concurrent multi-threaded reads of `client.configuration`
///    while background re-discovery actively updates configuration must be race-free.
/// 5. Error typing under concurrent discovery failure.
final class DiscoveryRecoveryChallengerTests: XCTestCase {

  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("challenger-discovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDir {
      try? FileManager.default.removeItem(at: tempDir)
    }
  }

  // MARK: - Test Helpers

  actor AtomicProbeTracker {
    private(set) var probeCount = 0
    private(set) var probedPorts: [UInt16] = []
    private(set) var probedTokens: [String] = []

    func recordProbe(port: UInt16, token: String) {
      probeCount += 1
      probedPorts.append(port)
      probedTokens.append(token)
    }

    var count: Int { probeCount }
  }

  actor ScriptedChallengerTransport: TailscaleTransport {
    private(set) var callCount = 0
    private(set) var requestsByPort: [UInt16: Int] = [:]
    private(set) var requestsByToken: [String: Int] = [:]
    private(set) var requestsByMethod: [String: Int] = [:]

    private var sendHandler:
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
      requestsByMethod[request.method, default: 0] += 1
      if let token = configuration.authToken {
        requestsByToken[token, default: 0] += 1
      }
      if case .loopback(_, let port) = configuration.endpoint {
        requestsByPort[port, default: 0] += 1
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
      if case .loopback(_, let port) = configuration.endpoint {
        requestsByPort[port, default: 0] += 1
      }
      throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1")
    }

    var totalCalls: Int { callCount }
    func countForPort(_ port: UInt16) -> Int { requestsByPort[port, default: 0] }
    func countForMethod(_ method: String) -> Int { requestsByMethod[method, default: 0] }
    func countForToken(_ token: String) -> Int { requestsByToken[token, default: 0] }
  }

  private static func setupStandaloneDirectory(in dir: URL, port: UInt16, token: String) throws {
    let ipnportURL = dir.appendingPathComponent("ipnport")
    try? FileManager.default.removeItem(at: ipnportURL)
    try FileManager.default.createSymbolicLink(
      atPath: ipnportURL.path, withDestinationPath: "\(port)")
    let tokenURL = dir.appendingPathComponent("sameuserproof-\(port)")
    try? FileManager.default.removeItem(at: tokenURL)
    try "\(token)\n".write(to: tokenURL, atomically: true, encoding: .utf8)
  }

  // MARK: - Challenge 1: Concurrency Stampede & Single-Flight Coalescing

  func testStampede120ConcurrentRequestsCoalesceToSingleRediscovery() async throws {
    let transport = ScriptedChallengerTransport()
    let tracker = AtomicProbeTracker()

    let initialPort: UInt16 = 40001
    let newPort: UInt16 = 40002
    let initialToken = "stale-token-123"
    let newToken = "restarted-token-456"

    try Self.setupStandaloneDirectory(in: tempDir, port: newPort, token: newToken)

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task {
          await tracker.recordProbe(port: port, token: token)
        }
        // Artificial delay simulating probe network / filesystem roundtrip
        usleep(30_000)
        return true
      }
    )

    await transport.setHandler { request, config in
      if case .loopback(_, let port) = config.endpoint, port == initialPort {
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(initialPort)")
      }
      if case .loopback(_, let port) = config.endpoint, port == newPort {
        XCTAssertEqual(config.authToken, newToken)
        return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
      }
      throw TailscaleTransportError.networkFailure(underlying: POSIXError(.ECONNABORTED))
    }

    let initialConfig = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: initialPort),
        authToken: initialToken,
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: initialConfig)

    let concurrentRequestCount = 120
    var responses: [StatusResponse] = []
    responses.reserveCapacity(concurrentRequestCount)

    try await withThrowingTaskGroup(of: StatusResponse.self) { group in
      for _ in 0..<concurrentRequestCount {
        group.addTask {
          try await client.status()
        }
      }
      for try await response in group {
        responses.append(response)
      }
    }

    // 1. All 120 requests succeeded
    XCTAssertEqual(responses.count, concurrentRequestCount)
    for res in responses {
      XCTAssertEqual(res.backendState, .running)
    }

    // 2. Exactly ONE re-discovery occurred
    let probeCount = await tracker.count
    XCTAssertEqual(
      probeCount, 1,
      "Stampede of \(concurrentRequestCount) requests must trigger exactly 1 rediscovery probe")

    // 3. Client configuration was updated
    let updatedConfig = client.configuration
    XCTAssertEqual(updatedConfig.endpoint, .loopback(host: "127.0.0.1", port: newPort))
    XCTAssertEqual(updatedConfig.authToken, newToken)

    // 4. Transport calls: 120 failed on initial port, 120 retried and succeeded on new port
    let callsOnOldPort = await transport.countForPort(initialPort)
    let callsOnNewPort = await transport.countForPort(newPort)
    XCTAssertLessThanOrEqual(callsOnOldPort, concurrentRequestCount)
    XCTAssertGreaterThanOrEqual(callsOnOldPort, 1)
    XCTAssertEqual(callsOnNewPort, concurrentRequestCount)
  }

  func testStampede100ConcurrentRequestsHTTP401CoalesceToSingleRediscovery() async throws {
    let transport = ScriptedChallengerTransport()
    let tracker = AtomicProbeTracker()

    let port: UInt16 = 40010
    let staleToken = "expired-token"
    let refreshedToken = "refreshed-valid-token"

    try Self.setupStandaloneDirectory(in: tempDir, port: port, token: refreshedToken)

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task {
          await tracker.recordProbe(port: port, token: token)
        }
        usleep(25_000)
        return true
      }
    )

    await transport.setHandler { request, config in
      if config.authToken == staleToken {
        return TailscaleResponse(statusCode: 401, data: Data("401 Unauthorized".utf8))
      }
      if config.authToken == refreshedToken {
        return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
      }
      return TailscaleResponse(statusCode: 403, data: Data("403 Forbidden".utf8))
    }

    let initialConfig = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: port),
        authToken: staleToken,
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: initialConfig)

    let concurrentRequestCount = 100
    try await withThrowingTaskGroup(of: StatusResponse.self) { group in
      for _ in 0..<concurrentRequestCount {
        group.addTask {
          try await client.status()
        }
      }
      for try await response in group {
        XCTAssertEqual(response.backendState, .running)
      }
    }

    let probeCount = await tracker.count
    XCTAssertEqual(probeCount, 1, "HTTP 401 stampede must trigger exactly 1 rediscovery probe")
    XCTAssertEqual(client.configuration.authToken, refreshedToken)
  }

  func testRequestsArrivingWhileRediscoveryIsInFlightWaitAndAvoidStaleAttempt() async throws {
    let transport = ScriptedChallengerTransport()
    let tracker = AtomicProbeTracker()

    let initialPort: UInt16 = 40020
    let newPort: UInt16 = 40021
    let initialToken = "token-early"
    let newToken = "token-recovered"

    try Self.setupStandaloneDirectory(in: tempDir, port: newPort, token: newToken)

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task {
          await tracker.recordProbe(port: port, token: token)
        }
        usleep(60_000)  // 60ms delay
        return true
      }
    )

    await transport.setHandler { request, config in
      if case .loopback(_, let port) = config.endpoint, port == initialPort {
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(initialPort)")
      }
      if case .loopback(_, let port) = config.endpoint, port == newPort {
        return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
      }
      throw TailscaleTransportError.networkFailure(underlying: POSIXError(.ECONNRESET))
    }

    let initialConfig = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: initialPort),
        authToken: initialToken,
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: initialConfig)

    // Group 1: 30 requests launch immediately and trigger rediscovery
    // Group 2: 30 requests launch after 15ms (while rediscovery is in flight)
    try await withThrowingTaskGroup(of: StatusResponse.self) { group in
      for _ in 0..<30 {
        group.addTask {
          try await client.status()
        }
      }

      group.addTask {
        try await Task.sleep(nanoseconds: 15_000_000)  // 15ms
        return try await client.status()
      }

      for _ in 0..<29 {
        group.addTask {
          try await Task.sleep(nanoseconds: 15_000_000)
          return try await client.status()
        }
      }

      for try await response in group {
        XCTAssertEqual(response.backendState, .running)
      }
    }

    let probeCount = await tracker.count
    XCTAssertEqual(
      probeCount, 1,
      "Requests launched during in-flight rediscovery must coalesce into the same probe")

    // The late arrivals waited on inFlight.value, so they sent directly to newPort without attempting initialPort
    let callsOnOldPort = await transport.countForPort(initialPort)
    let callsOnNewPort = await transport.countForPort(newPort)
    XCTAssertEqual(callsOnOldPort, 30, "Late arrivals must not send on the stale port")
    XCTAssertEqual(callsOnNewPort, 60, "All 60 requests must complete on the new port")
  }

  // MARK: - Challenge 2: Mutation Safety Under Daemon Disconnect

  func testMutationSafetyZeroDuplicateExecutionsOnAmbiguousMalformedResponse() async throws {
    let transport = ScriptedChallengerTransport()
    let tracker = AtomicProbeTracker()

    let port: UInt16 = 40030
    try Self.setupStandaloneDirectory(in: tempDir, port: port, token: "mut-token")

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task { await tracker.recordProbe(port: port, token: token) }
        return true
      }
    )

    // Ambiguous failure: malformed response or broken pipe during response read
    await transport.setHandler { request, _ in
      XCTAssertEqual(request.method, "POST")
      throw TailscaleTransportError.malformedResponse(detail: "Broken pipe during POST read")
    }

    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: port),
        authToken: "mut-token",
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let mutatingCallCount = 50
    var errorCount = 0

    await withTaskGroup(of: Result<Void, Error>.self) { group in
      for i in 0..<mutatingCallCount {
        group.addTask {
          do {
            try await client.setDNS(name: "node-\(i).tailnet.local", value: "100.64.0.\(i)")
            return .success(())
          } catch {
            return .failure(error)
          }
        }
      }

      for await result in group {
        switch result {
        case .success:
          XCTFail("Mutating call during malformedResponse should not succeed")
        case .failure(let error):
          errorCount += 1
          guard case TailscaleClientError.transport(.malformedResponse) = error else {
            XCTFail("Expected TailscaleClientError.transport(.malformedResponse), got \(error)")
            continue
          }
        }
      }
    }

    XCTAssertEqual(errorCount, mutatingCallCount)

    // Strict assertion: EXACTLY 50 calls on transport (zero retries, zero duplicate execution)
    let totalTransportCalls = await transport.totalCalls
    XCTAssertEqual(
      totalTransportCalls, mutatingCallCount,
      "Ambiguous transport errors on mutating requests must NEVER be retried"
    )

    // Strict assertion: zero re-discovery passes
    let probeCount = await tracker.count
    XCTAssertEqual(probeCount, 0, "Ambiguous transport errors must never trigger rediscovery")
  }

  func testMutationSafetyZeroDuplicateExecutionsOnNetworkReset() async throws {
    let transport = ScriptedChallengerTransport()

    let port: UInt16 = 40035
    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: port),
      authToken: "token-mut",
      transport: transport,
      endpointSource: .automatic(LocalAPIDiscovery(environment: [:]))
    )
    let client = TailscaleClient(configuration: config)

    // Test network failure (e.g. ECONNRESET mid-stream)
    await transport.setHandler { _, _ in
      throw TailscaleTransportError.networkFailure(underlying: POSIXError(.ECONNRESET))
    }

    do {
      try await client.setDNS(name: "test.local", value: "1.2.3.4")
      XCTFail("Expected networkFailure")
    } catch let error as TailscaleClientError {
      guard case .transport(.networkFailure) = error else {
        XCTFail("Expected .transport(.networkFailure), got \(error)")
        return
      }
    }

    let callCount = await transport.totalCalls
    XCTAssertEqual(callCount, 1, "ECONNRESET on mutation must never replay")
  }

  func testMutationSafetyAllowsConnectStageReplayOnceOnDaemonRestart() async throws {
    let transport = ScriptedChallengerTransport()
    let tracker = AtomicProbeTracker()

    let initialPort: UInt16 = 40040
    let newPort: UInt16 = 40041
    let token = "post-replay-token"

    try Self.setupStandaloneDirectory(in: tempDir, port: newPort, token: token)

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task { await tracker.recordProbe(port: port, token: token) }
        usleep(20_000)
        return true
      }
    )

    await transport.setHandler { request, config in
      if case .loopback(_, let port) = config.endpoint, port == initialPort {
        // Connect stage error: zero bytes sent, connection refused
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(initialPort)")
      }
      if case .loopback(_, let port) = config.endpoint, port == newPort {
        return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
      }
      throw TailscaleTransportError.networkFailure(underlying: POSIXError(.ECONNABORTED))
    }

    let initialConfig = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: initialPort),
        authToken: token,
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: initialConfig)

    let count = 40
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<count {
        group.addTask {
          try await client.setDNS(name: "node-\(i).tailnet.local", value: "100.64.0.\(i)")
        }
      }
      try await group.waitForAll()
    }

    // Connect-stage errors are safe to replay because zero bytes were received by the daemon
    let probeCount = await tracker.count
    XCTAssertEqual(probeCount, 1)

    let oldPortCalls = await transport.countForPort(initialPort)
    let newPortCalls = await transport.countForPort(newPort)
    XCTAssertEqual(oldPortCalls, count, "All mutations attempted on initial port")
    XCTAssertEqual(newPortCalls, count, "All mutations replayed exactly once on new port")
  }

  // MARK: - Challenge 3: Pinned Immutability

  func testPinnedEndpointNeverTriggersRediscoveryUnderRepeatedFailures() async throws {
    let transport = ScriptedChallengerTransport()
    let tracker = AtomicProbeTracker()

    let pinnedPort: UInt16 = 33333
    let pinnedToken = "pinned-immutable-secret"
    let pinnedEndpoint = TailscaleEndpoint.loopback(host: "127.0.0.1", port: pinnedPort)

    try Self.setupStandaloneDirectory(in: tempDir, port: 44444, token: "should-never-be-discovered")

    await transport.setHandler { request, config in
      throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(pinnedPort)")
    }

    let config = TailscaleClientConfiguration(
      endpoint: pinnedEndpoint,
      authToken: pinnedToken,
      transport: transport,
      endpointSource: .pinned(pinnedEndpoint)
    )
    let client = TailscaleClient(configuration: config)

    // 1. 50 successive unary connectionRefused failures
    for _ in 0..<50 {
      do {
        _ = try await client.status()
        XCTFail("Expected connectionRefused")
      } catch let error as TailscaleClientError {
        guard case .transport(.connectionRefused) = error else {
          XCTFail("Expected .transport(.connectionRefused), got \(error)")
          break
        }
      }
    }

    // 2. 50 successive unary 401 Unauthorized failures
    await transport.setHandler { _, _ in
      TailscaleResponse(statusCode: 401, data: Data("401 Unauthorized".utf8))
    }

    for _ in 0..<50 {
      do {
        _ = try await client.status()
        XCTFail("Expected permissionDenied or unexpectedStatus")
      } catch let error as TailscaleClientError {
        switch error {
        case .permissionDenied, .unexpectedStatus(401, _, _):
          break
        default:
          XCTFail("Expected permissionDenied or unexpectedStatus(401), got \(error)")
        }
      }
    }

    // 3. 10 streaming connectionRefused failures
    for _ in 0..<10 {
      do {
        let stream = try await client.watchIPNBusEvents()
        for try await _ in stream {}
        XCTFail("Expected streaming error")
      } catch let error as TailscaleClientError {
        guard case .transport(.connectionRefused) = error else {
          XCTFail("Expected streaming .transport(.connectionRefused), got \(error)")
          break
        }
      }
    }

    // 4. Assert pinned immutability
    let probeCount = await tracker.count
    XCTAssertEqual(
      probeCount, 0, "Pinned client must NEVER trigger discovery under repeated failures")

    let activeConfig = client.configuration
    XCTAssertEqual(
      activeConfig.endpoint, pinnedEndpoint, "Pinned endpoint must be strictly immutable")
    XCTAssertEqual(
      activeConfig.authToken, pinnedToken, "Pinned auth token must be strictly immutable")

    // 5. Total transport calls must be exactly 110 (50 + 50 + 10 = exactly 1 call per request, 0 retries)
    let totalCalls = await transport.totalCalls
    XCTAssertEqual(totalCalls, 110, "Pinned client must perform zero retries on failure")

    // 6. Direct invocation of singleFlightRediscovery must throw permissionDenied
    do {
      _ = try await client.singleFlightRediscovery()
      XCTFail("Expected permissionDenied on pinned client rediscovery")
    } catch let error as TailscaleClientError {
      guard case .permissionDenied = error else {
        XCTFail("Expected .permissionDenied, got \(error)")
        return
      }
    }
  }

  // MARK: - Challenge 4: Nonisolated Thread Safety Stress Test

  actor FlipFlopDiscovery {
    let portA: UInt16
    let portB: UInt16
    let tokenA: String
    let tokenB: String
    var currentIsA = true

    init(portA: UInt16, portB: UInt16, tokenA: String, tokenB: String) {
      self.portA = portA
      self.portB = portB
      self.tokenA = tokenA
      self.tokenB = tokenB
    }

    func toggle() -> (port: UInt16, token: String) {
      currentIsA.toggle()
      return currentIsA ? (portA, tokenA) : (portB, tokenB)
    }
  }

  func testNonisolatedConfigurationThreadSafetyUnderHeavyConcurrentReadsAndUpdates() async throws {
    let transport = ScriptedChallengerTransport()

    let portA: UInt16 = 42001
    let portB: UInt16 = 42002
    let tokenA = "token-alpha-1111111111"
    let tokenB = "token-beta-22222222222"

    try Self.setupStandaloneDirectory(in: tempDir, port: portA, token: tokenA)

    let flipper = FlipFlopDiscovery(portA: portA, portB: portB, tokenA: tokenA, tokenB: tokenB)

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        true
      }
    )

    let initialConfig = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: portA),
        authToken: tokenA,
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: initialConfig)

    actor ReadStats {
      var totalReads = 0
      var observedRedactedCount = 0
      func record(isRedacted: Bool) {
        totalReads += 1
        if isRedacted { observedRedactedCount += 1 }
      }
    }
    let stats = ReadStats()

    // Launch 10 reader tasks continuously hammering nonisolated client.configuration
    let readerCount = 10
    let readIterationsPerTask = 3000
    let standaloneDir = tempDir!

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<readerCount {
        group.addTask {
          for _ in 0..<readIterationsPerTask {
            // Read nonisolated configuration from arbitrary concurrent task
            let config = client.configuration

            // Verify properties are valid and Sendable
            let desc = config.description
            _ = config.customMirror
            let isRedacted = desc.contains("<redacted>")

            // Verify no token leaking in description
            XCTAssertFalse(desc.contains(tokenA))
            XCTAssertFalse(desc.contains(tokenB))

            // Verify endpoint consistency
            switch config.endpoint {
            case .loopback(_, let port):
              XCTAssertTrue(port == portA || port == portB)
            default:
              XCTFail("Unexpected endpoint: \(config.endpoint)")
            }

            await stats.record(isRedacted: isRedacted)
          }
        }
      }

      // Writer task: rapidly updates directory and triggers re-discovery
      group.addTask {
        for _ in 0..<40 {
          let (nextPort, nextToken) = await flipper.toggle()
          try Self.setupStandaloneDirectory(in: standaloneDir, port: nextPort, token: nextToken)
          do {
            _ = try await client.singleFlightRediscovery()
          } catch {
            // Rediscovery may throw if mocked environment is mid-write
          }
          try await Task.sleep(nanoseconds: 1_000_000)  // 1ms
        }
      }

      try await group.waitForAll()
    }

    let totalReads = await stats.totalReads
    let redactedReads = await stats.observedRedactedCount
    XCTAssertEqual(totalReads, readerCount * readIterationsPerTask)
    XCTAssertEqual(
      redactedReads, totalReads, "All configuration reads must consistently redact the token")
  }

  // MARK: - Challenge 5: Concurrent Discovery Failure & Error Consistency

  func testConcurrentDiscoveryFailureThrowsTypedErrorAcrossAllCallers() async throws {
    let transport = ScriptedChallengerTransport()
    let tracker = AtomicProbeTracker()

    let deadPort: UInt16 = 40099
    try Self.setupStandaloneDirectory(in: tempDir, port: deadPort, token: "dead-token")

    // Discovery probe always returns false, simulating stopped daemon
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task { await tracker.recordProbe(port: port, token: token) }
        usleep(20_000)
        return false  // candidate is dead!
      }
    )

    await transport.setHandler { _, _ in
      throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(deadPort)")
    }

    let initialConfig = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: deadPort),
        authToken: "dead-token",
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: initialConfig)

    let concurrentCallCount = 30
    var clientErrorCount = 0
    var rawDiscoveryErrorCount = 0

    await withTaskGroup(of: Result<StatusResponse, Error>.self) { group in
      for _ in 0..<concurrentCallCount {
        group.addTask {
          do {
            let res = try await client.status()
            return .success(res)
          } catch {
            return .failure(error)
          }
        }
      }

      for await result in group {
        switch result {
        case .success:
          XCTFail("Requests against dead daemon must not succeed")
        case .failure(let error):
          if let clientError = error as? TailscaleClientError {
            if case .discovery = clientError {
              clientErrorCount += 1
            } else {
              XCTFail("Expected .discovery error, got \(clientError)")
            }
          } else if error is LocalAPIDiscoveryError {
            rawDiscoveryErrorCount += 1
          } else {
            XCTFail("Unexpected error type: \(error)")
          }
        }
      }
    }

    // Empirical demonstration of error typing bug:
    // Public API contract states methods throw TailscaleClientError.
    // However, coalesced callers awaiting inFlight.value throw raw LocalAPIDiscoveryError.
    XCTAssertEqual(
      clientErrorCount, concurrentCallCount,
      "All \(concurrentCallCount) concurrent callers should receive TailscaleClientError.discovery, but \(rawDiscoveryErrorCount) received raw LocalAPIDiscoveryError"
    )
    let probeCount = await tracker.count
    XCTAssertEqual(
      probeCount, 1, "Even when discovery fails, single-flight coalescing must occur exactly once")
  }
}
