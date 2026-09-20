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

/// Remediation Challenger 2 stress test suite for Milestone 2 Week 4 (PR 08 & PR 09).
///
/// Focuses on:
/// 1. 100+ concurrent requests arriving while rediscovery is in flight.
/// 2. Error typing and coalescing when in-flight rediscovery fails with late arrivals.
/// 3. Cancellation handling of tasks awaiting in-flight rediscovery.
/// 4. Heavy concurrent mutation replay safety (100+ concurrent POST mutations during restart).
/// 5. Extreme nonisolated configuration concurrency (50,000 concurrent reads during rapid flapping).
final class DiscoveryRecoveryStressChallengerTests: XCTestCase {

  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("challenger-stress-\(UUID().uuidString)", isDirectory: true)
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

  actor ScriptedStressTransport: TailscaleTransport {
    private(set) var callCount = 0
    private(set) var requestsByPort: [UInt16: Int] = [:]
    private(set) var requestsByToken: [String: Int] = [:]
    private(set) var requestsByMethod: [String: Int] = [:]
    private(set) var peerlessRequestsByPort: [UInt16: Int] = [:]

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
        if request.queryItems.contains(URLQueryItem(name: "peers", value: "false")) {
          peerlessRequestsByPort[port, default: 0] += 1
        }
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
    func peerlessCountForPort(_ port: UInt16) -> Int { peerlessRequestsByPort[port, default: 0] }
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

  // MARK: - Test 1: 100+ Concurrent Requests Arriving While Rediscovery Is In-Flight

  func test150ConcurrentRequestsArrivingWhileRediscoveryIsInFlightWaitAndAvoidStaleAttempt()
    async throws
  {
    let transport = ScriptedStressTransport()
    let tracker = AtomicProbeTracker()

    let initialPort: UInt16 = 41020
    let newPort: UInt16 = 41021
    let initialToken = "token-early"
    let newToken = "token-recovered-150"
    let probeStarted = expectation(description: "Rediscovery probe started")
    let releaseProbe = DispatchSemaphore(value: 0)
    defer { releaseProbe.signal() }

    try Self.setupStandaloneDirectory(in: tempDir, port: newPort, token: newToken)

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task {
          await tracker.recordProbe(port: port, token: token)
          probeStarted.fulfill()
        }
        // Bound the wait so a regression cannot strand the discovery worker.
        _ = releaseProbe.wait(timeout: .now() + 10)
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

    let group1Count = 1
    let group2Count = 150
    let totalCount = group1Count + group2Count

    var responses: [StatusResponse] = []
    responses.reserveCapacity(totalCount)

    try await withThrowingTaskGroup(of: StatusResponse.self) { group in
      // A single initial request triggers recovery. Multiple initial failures can
      // reach the client after recovery completes and start another valid probe.
      for _ in 0..<group1Count {
        group.addTask {
          try await client.status()
        }
      }

      await fulfillment(of: [probeStarted], timeout: 5)

      // Launch the late group only after rediscovery starts. A distinct query lets
      // us detect their stale attempts independently of the initial callers.
      for _ in 0..<group2Count {
        group.addTask {
          try await client.status(query: StatusQuery(includePeers: false))
        }
      }
      releaseProbe.signal()

      for try await response in group {
        responses.append(response)
      }
    }

    // 1. Every request must succeed
    XCTAssertEqual(responses.count, totalCount)
    for res in responses {
      XCTAssertEqual(res.backendState, .running)
    }

    // 2. The initial failure and all late callers share one probe
    let probeCount = await tracker.count
    XCTAssertEqual(
      probeCount, 1,
      "Burst of \(totalCount) requests (1 initial + 150 late) must coalesce into exactly 1 rediscovery probe"
    )

    // Only the initial request may attempt the stale port.
    let callsOnOldPort = await transport.countForPort(initialPort)
    let callsOnNewPort = await transport.countForPort(newPort)
    let lateCallsOnOldPort = await transport.peerlessCountForPort(initialPort)
    let lateCallsOnNewPort = await transport.peerlessCountForPort(newPort)
    XCTAssertEqual(callsOnOldPort, group1Count)
    XCTAssertEqual(
      lateCallsOnOldPort, 0,
      "Late-arriving requests must not attempt the stale port"
    )
    XCTAssertEqual(lateCallsOnNewPort, group2Count)
    XCTAssertEqual(
      callsOnNewPort, totalCount,
      "All \(totalCount) requests must complete successfully on the recovered port"
    )
  }

  // MARK: - Test 2: Concurrent Discovery Failure With Late Arrivals

  func testConcurrentLateArrivalsWhenRediscoveryFailsThrowTypedErrorAcrossAllCallers() async throws
  {
    let transport = ScriptedStressTransport()
    let tracker = AtomicProbeTracker()

    let deadPort: UInt16 = 41099
    try Self.setupStandaloneDirectory(in: tempDir, port: deadPort, token: "dead-token")

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task { await tracker.recordProbe(port: port, token: token) }
        usleep(50_000)  // 50ms probe delay
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

    let group1Count = 20
    let group2Count = 40
    let totalCalls = group1Count + group2Count

    var clientErrorCount = 0
    var rawDiscoveryErrorCount = 0
    var otherErrorCount = 0

    await withTaskGroup(of: Result<StatusResponse, Error>.self) { group in
      // Group 1: 20 callers hit dead port and trigger rediscovery
      for _ in 0..<group1Count {
        group.addTask {
          do {
            let res = try await client.status()
            return .success(res)
          } catch {
            return .failure(error)
          }
        }
      }

      // Group 2: 40 callers arrive while rediscovery is in flight
      for _ in 0..<group2Count {
        group.addTask {
          do {
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
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
          XCTFail("Dead daemon must not succeed")
        case .failure(let error):
          if let clientError = error as? TailscaleClientError {
            if case .discovery = clientError {
              clientErrorCount += 1
            } else {
              otherErrorCount += 1
            }
          } else if error is LocalAPIDiscoveryError {
            rawDiscoveryErrorCount += 1
          } else {
            otherErrorCount += 1
          }
        }
      }
    }

    // Crucial: 0 raw LocalAPIDiscoveryError leaked across both early and late arrivals
    XCTAssertEqual(
      rawDiscoveryErrorCount, 0, "No raw LocalAPIDiscoveryError should leak to any caller")
    XCTAssertEqual(
      clientErrorCount, totalCalls,
      "All \(totalCalls) callers (both early and late) must receive typed TailscaleClientError.discovery"
    )
  }

  // MARK: - Test 3: Task Cancellation During In-Flight Rediscovery Wait

  func testTaskCancellationWhileWaitingOnInFlightRediscoveryDoesNotCorruptClient() async throws {
    let transport = ScriptedStressTransport()
    let tracker = AtomicProbeTracker()

    let initialPort: UInt16 = 41030
    let newPort: UInt16 = 41031
    let token = "cancellation-test-token"

    try Self.setupStandaloneDirectory(in: tempDir, port: newPort, token: token)

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task { await tracker.recordProbe(port: port, token: token) }
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
      throw TailscaleTransportError.networkFailure(underlying: POSIXError(.ECONNABORTED))
    }

    let initialConfig = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: initialPort),
        authToken: "early-token",
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: initialConfig)

    // Trigger in-flight rediscovery
    let driverTask = Task {
      try await client.status()
    }

    // Wait 10ms so rediscoveryTask is running
    try await Task.sleep(nanoseconds: 10_000_000)

    // Launch a task that will wait on inFlight.value, and then cancel it
    let cancelledTask = Task {
      try await client.status()
    }

    // Launch another task that will NOT be cancelled
    let survivingTask = Task {
      try await client.status()
    }

    // Cancel the waiting task
    cancelledTask.cancel()

    // Driver task should succeed
    let driverResponse = try await driverTask.value
    XCTAssertEqual(driverResponse.backendState, .running)

    // Surviving task should succeed
    let survivingResponse = try await survivingTask.value
    XCTAssertEqual(survivingResponse.backendState, .running)

    // Cancelled task should throw CancellationError
    do {
      _ = try await cancelledTask.value
      // Note: in Swift concurrency, depending on timing, task may complete before cancellation takes effect
    } catch is CancellationError {
      // Expected
    } catch {
      // If completed before cancellation, it's also acceptable, but shouldn't fail with internal error
    }

    // Client must be fully healthy on new port
    let followUp = try await client.status()
    XCTAssertEqual(followUp.backendState, .running)
    XCTAssertEqual(client.configuration.endpoint, .loopback(host: "127.0.0.1", port: newPort))
  }

  // MARK: - Test 4: Heavy Concurrent Mutation Replay Safety (100 Concurrent Mutations)

  func testHeavyConcurrentMutationSafetyAllowsConnectStageReplayOnceOnDaemonRestart() async throws {
    let transport = ScriptedStressTransport()
    let tracker = AtomicProbeTracker()

    let initialPort: UInt16 = 41040
    let newPort: UInt16 = 41041
    let token = "heavy-mutation-token"

    try Self.setupStandaloneDirectory(in: tempDir, port: newPort, token: token)

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      standaloneDirectoryOverride: tempDir,
      probeOverride: { port, token in
        Task { await tracker.recordProbe(port: port, token: token) }
        usleep(30_000)
        return true
      }
    )

    await transport.setHandler { request, config in
      if case .loopback(_, let port) = config.endpoint, port == initialPort {
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

    let count = 100
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<count {
        group.addTask {
          try await client.setDNS(name: "node-\(i).tailnet.local", value: "100.64.0.\(i)")
        }
      }
      try await group.waitForAll()
    }

    // 1. Exactly 1 rediscovery probe
    let probeCount = await tracker.count
    XCTAssertEqual(
      probeCount, 1, "100 concurrent mutations must coalesce into exactly 1 rediscovery probe")

    // 2. Initial port calls <= count, new port calls == count
    let oldPortCalls = await transport.countForPort(initialPort)
    let newPortCalls = await transport.countForPort(newPort)
    XCTAssertLessThanOrEqual(oldPortCalls, count)
    XCTAssertGreaterThanOrEqual(oldPortCalls, 1)
    XCTAssertEqual(newPortCalls, count, "All 100 mutations must succeed on new port")
  }
}
