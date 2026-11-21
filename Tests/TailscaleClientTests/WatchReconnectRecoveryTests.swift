// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

/// Reconnects of a long-lived IPN bus watch (`watchIPNBusEvents`, which
/// `watchIPNBus` wraps) after a daemon restart that
/// changes the loopback port or proof token. The reconnect must rediscover the
/// daemon exactly like the initial open does when the endpoint source is
/// `.automatic`, and must never rediscover for a pinned configuration.
final class WatchReconnectRecoveryTests: XCTestCase {

  // MARK: - Harness

  struct RecordedOpen: Sendable {
    let endpoint: TailscaleEndpoint
    let token: String?
    let mask: String?
  }

  /// Streaming transport that records each open and answers through a
  /// per-test handler keyed on the configuration the client sent.
  actor RestartingDaemonTransport: TailscaleTransport {
    private(set) var opens: [RecordedOpen] = []
    private(set) var unaryCalls: [RecordedOpen] = []
    private var streamHandler:
      (
        @Sendable (Int, TailscaleClientConfiguration) async throws -> StreamingResponse
      )?
    private var unaryHandler:
      (
        @Sendable (TailscaleClientConfiguration) async throws -> TailscaleResponse
      )?

    func setStreamHandler(
      _ handler:
        @escaping @Sendable (Int, TailscaleClientConfiguration) async throws -> StreamingResponse
    ) {
      streamHandler = handler
    }

    func setUnaryHandler(
      _ handler:
        @escaping @Sendable (TailscaleClientConfiguration) async throws -> TailscaleResponse
    ) {
      unaryHandler = handler
    }

    func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration) async throws
      -> TailscaleResponse
    {
      unaryCalls.append(
        RecordedOpen(endpoint: configuration.endpoint, token: configuration.authToken, mask: nil))
      guard let unaryHandler else { throw TailscaleTransportError.unimplemented }
      return try await unaryHandler(configuration)
    }

    func sendStreaming(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
      async throws -> StreamingResponse
    {
      let mask = request.queryItems.first(where: { $0.name == "mask" })?.value
      opens.append(
        RecordedOpen(endpoint: configuration.endpoint, token: configuration.authToken, mask: mask))
      let index = opens.count - 1
      guard let streamHandler else { throw TailscaleTransportError.unimplemented }
      return try await streamHandler(index, configuration)
    }
  }

  /// A 200 stream that yields `versions` as notifications, then either
  /// closes (daemon went away) or stays open until the consumer cancels.
  static func notifyStream(_ versions: [String], thenClose: Bool) -> StreamingResponse {
    StreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        for version in versions {
          continuation.yield(Data("{\"Version\":\"\(version)\"}".utf8))
        }
        if thenClose { continuation.finish() }
      }
    )
  }

  static func statusOnly(_ code: Int) -> StreamingResponse {
    StreamingResponse(
      statusCode: code,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(Data("rejected".utf8))
        continuation.finish()
      }
    )
  }

  static func port(of endpoint: TailscaleEndpoint) -> UInt16? {
    if case .loopback(_, let port) = endpoint { return port }
    return nil
  }

  static let fastReconnect = StreamRetryPolicy(
    maxAttempts: 3, initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), jitter: 0)

  /// Collects notification versions until `stopAt` arrives, the stream ends,
  /// or two seconds pass. Returns the versions and the terminating error, if any.
  static func collectVersions(
    _ stream: AsyncThrowingStream<IPNBusEvent, Error>, stopAt: String
  ) async -> (versions: [String], error: Error?) {
    await withTaskGroup(of: ([String], Error?)?.self) { group in
      group.addTask {
        var versions: [String] = []
        do {
          for try await event in stream {
            guard case .notification(let notify) = event else { continue }
            if let version = notify.version { versions.append(version) }
            if notify.version == stopAt { break }
          }
          return (versions, nil)
        } catch {
          return (versions, error)
        }
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? ([], TailscaleClientError.timeout(endpoint: "test-collect"))
    }
  }

  // MARK: - Automatic source: connection refused on the old port

  func testReconnectRediscoversWhenOldEndpointRefusesConnections() async throws {
    let transport = RestartingDaemonTransport()
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "41201",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-new",
      ]
    )
    await transport.setStreamHandler { index, config in
      if Self.port(of: config.endpoint) == 41200 {
        if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:41200")
      }
      return Self.notifyStream(["new-1"], thenClose: false)
    }
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 41200), authToken: "token-old",
        capabilityVersion: 144),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let stream = try await client.watchIPNBusEvents(retryPolicy: Self.fastReconnect)
    let (versions, error) = await Self.collectVersions(stream, stopAt: "new-1")

    XCTAssertNil(error)
    XCTAssertEqual(versions, ["old-1", "new-1"])
    let opens = await transport.opens
    let last = try XCTUnwrap(opens.last)
    XCTAssertEqual(last.endpoint, .loopback(host: "127.0.0.1", port: 41201))
    XCTAssertEqual(last.token, "token-new")
    XCTAssertEqual(client.configuration.endpoint, .loopback(host: "127.0.0.1", port: 41201))
    XCTAssertEqual(client.configuration.authToken, "token-new")
  }

  func testRecoveredReconnectPreservesCallerWatchOptions() async throws {
    let transport = RestartingDaemonTransport()
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "41211",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-new",
      ]
    )
    await transport.setStreamHandler { index, config in
      if Self.port(of: config.endpoint) == 41210 {
        if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:41210")
      }
      return Self.notifyStream(["new-1"], thenClose: false)
    }
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 41210), authToken: "token-old",
        capabilityVersion: 144),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)
    let options: NotifyWatchOpt = [.initialState, .initialNetMap, .noPrivateKeys]

    let stream = try await client.watchIPNBusEvents(
      options: options, retryPolicy: Self.fastReconnect)
    _ = await Self.collectVersions(stream, stopAt: "new-1")

    let opens = await transport.opens
    let recovered = opens.filter { Self.port(of: $0.endpoint) == 41211 }
    XCTAssertFalse(recovered.isEmpty, "Expected a reconnect to the rediscovered endpoint")
    for open in opens {
      XCTAssertEqual(open.mask, String(options.rawValue))
    }
  }

  func testRecoveredReconnectEmitsStandardReconnectLifecycle() async throws {
    let transport = RestartingDaemonTransport()
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "41221",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-new",
      ]
    )
    await transport.setStreamHandler { index, config in
      if Self.port(of: config.endpoint) == 41220 {
        if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:41220")
      }
      return Self.notifyStream(["new-1"], thenClose: false)
    }
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 41220), authToken: "token-old",
        capabilityVersion: 144),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)
    let stream = try await client.watchIPNBusEvents(retryPolicy: Self.fastReconnect)
    var labels: [String] = []
    for try await event in stream {
      switch event {
      case .notification(let notify):
        labels.append("notify:\(notify.version ?? "")")
      case .lifecycle(.connected):
        labels.append("connected")
      case .lifecycle(.retrying):
        labels.append("retrying")
      case .lifecycle(.stateGap(let reason)):
        labels.append("gap:\(reason)")
      case .lifecycle(.disconnected):
        labels.append("disconnected")
      default:
        labels.append("other")
      }
      if labels.last == "notify:new-1" || labels.count > 20 { break }
    }

    XCTAssertEqual(
      labels,
      [
        "connected", "notify:old-1", "disconnected", "retrying", "connected",
        "gap:reconnected", "notify:new-1",
      ])
  }

  // MARK: - Pinned source never rediscovers

  func testPinnedWatchRetriesOldEndpointWithoutRediscovery() async throws {
    let transport = RestartingDaemonTransport()
    let endpoint = TailscaleEndpoint.loopback(host: "127.0.0.1", port: 41230)
    await transport.setStreamHandler { index, _ in
      if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
      throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:41230")
    }
    let config = TailscaleClientConfiguration(
      endpoint: endpoint, authToken: "pinned-token", transport: transport,
      endpointSource: .pinned(endpoint))
    let client = TailscaleClient(configuration: config)

    let stream = try await client.watchIPNBusEvents(retryPolicy: Self.fastReconnect)
    let (versions, error) = await Self.collectVersions(stream, stopAt: "never")

    XCTAssertNil(error, "Retryable refusals exhaust the policy and end the stream")
    XCTAssertEqual(versions, ["old-1"])
    let opens = await transport.opens
    XCTAssertEqual(opens.count, 1 + 3, "Initial open plus maxAttempts reconnects")
    XCTAssertTrue(opens.allSatisfy { $0.endpoint == endpoint && $0.token == "pinned-token" })
    XCTAssertEqual(client.configuration.endpoint, endpoint)
    XCTAssertEqual(client.configuration.authToken, "pinned-token")
  }

  func testPinnedWatchFailsOn401WithoutRediscovery() async throws {
    let transport = RestartingDaemonTransport()
    let endpoint = TailscaleEndpoint.loopback(host: "127.0.0.1", port: 41240)
    await transport.setStreamHandler { index, _ in
      if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
      return Self.statusOnly(401)
    }
    let config = TailscaleClientConfiguration(
      endpoint: endpoint, authToken: "pinned-token", transport: transport,
      endpointSource: .pinned(endpoint))
    let client = TailscaleClient(configuration: config)

    let stream = try await client.watchIPNBusEvents(retryPolicy: Self.fastReconnect)
    let (versions, error) = await Self.collectVersions(stream, stopAt: "never")

    XCTAssertEqual(versions, ["old-1"])
    let thrown = try XCTUnwrap(error, "401 on reconnect is fatal for a pinned watch")
    XCTAssertEqual(StreamRetryPolicy.classify(thrown), .fatal)
    let opens = await transport.opens
    XCTAssertEqual(opens.count, 2)
    XCTAssertEqual(client.configuration.authToken, "pinned-token")
  }

  // MARK: - watchIPNBus (IPNNotify wrapper) across reconnects

  static let fastIPNReconnect = IPNBusReconnectPolicy(
    maxAttempts: 3, initialDelay: .milliseconds(10), maxDelay: .milliseconds(20))

  /// Collects notification versions from `watchIPNBus` until `stopAt`, the
  /// end of the stream, or two seconds. Returns the versions and any error.
  static func collectNotifyVersions(
    _ stream: AsyncThrowingStream<IPNNotify, Error>, stopAt: String
  ) async -> (versions: [String], error: Error?) {
    await withTaskGroup(of: ([String], Error?)?.self) { group in
      group.addTask {
        var versions: [String] = []
        do {
          for try await notify in stream {
            if let version = notify.version { versions.append(version) }
            if notify.version == stopAt { break }
          }
          return (versions, nil)
        } catch {
          return (versions, error)
        }
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? ([], TailscaleClientError.timeout(endpoint: "test-collect"))
    }
  }

  func testWatchIPNBusSurvivesPlainReconnect() async throws {
    let transport = MockTransport.scriptedStreams([
      [.jsonLine("{\"Version\":\"1.0\"}")],
      [.jsonLine("{\"Version\":\"2.0\"}")],
    ])
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .loopback(host: "127.0.0.1", port: 41280), authToken: "t",
        transport: transport))

    let stream = try await client.watchIPNBus(reconnect: Self.fastIPNReconnect)
    let (versions, error) = await Self.collectNotifyVersions(stream, stopAt: "2.0")

    XCTAssertNil(error, "A successful reconnect must not end the stream")
    XCTAssertEqual(versions, ["1.0", "2.0"])
  }

  func testWatchIPNBusFollowsRediscoveredDaemonAcrossReconnect() async throws {
    let transport = RestartingDaemonTransport()
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "41291",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-new",
      ]
    )
    await transport.setStreamHandler { index, config in
      if Self.port(of: config.endpoint) == 41290 {
        if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:41290")
      }
      return Self.notifyStream(["new-1"], thenClose: false)
    }
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 41290), authToken: "token-old",
        capabilityVersion: 144),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let stream = try await client.watchIPNBus(reconnect: Self.fastIPNReconnect)
    let (versions, error) = await Self.collectNotifyVersions(stream, stopAt: "new-1")

    XCTAssertNil(error)
    XCTAssertEqual(versions, ["old-1", "new-1"])
    let last = await transport.opens.last
    XCTAssertEqual(last?.endpoint, .loopback(host: "127.0.0.1", port: 41291))
    XCTAssertEqual(last?.token, "token-new")
  }

  func testWatchIPNBusSkipsUndecodableLineAndReportsIt() async throws {
    final class Reported: @unchecked Sendable {
      private let lock = NSLock()
      private var lines: [Data] = []
      func append(_ line: Data) {
        lock.lock()
        lines.append(line)
        lock.unlock()
      }
      var all: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return lines
      }
    }
    let reported = Reported()
    let malformed = Data("not json".utf8)
    let transport = MockTransport.scriptedStream([
      .jsonLine("{\"Version\":\"1.0\"}"),
      .line(malformed),
      .jsonLine("{\"Version\":\"2.0\"}"),
    ])
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .loopback(host: "127.0.0.1", port: 41300), authToken: "t",
        transport: transport))

    let stream = try await client.watchIPNBus(onUndecodableLine: { line, _ in
      reported.append(line)
    })
    let (versions, error) = await Self.collectNotifyVersions(stream, stopAt: "never")

    XCTAssertNil(error, "An undecodable line must not end the stream")
    XCTAssertEqual(versions, ["1.0", "2.0"])
    XCTAssertEqual(reported.all, [malformed])
  }

  func testWatchIPNBusStillThrowsStreamOverflowWhenBufferExceeded() async throws {
    // watchIPNBus uses `.throwing` bounds (256 events); overflow is raised by the queue itself.
    let lines = (1...400).map { MockStreamEvent.jsonLine("{\"Version\":\"1.\($0)\"}") }
    let transport = MockTransport.scriptedStream(lines)
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .loopback(host: "127.0.0.1", port: 41310), authToken: "t",
        transport: transport))

    let stream = try await client.watchIPNBus()
    var iterator = stream.makeAsyncIterator()
    _ = try await iterator.next()
    try await Task.sleep(for: .milliseconds(200))
    do {
      while try await iterator.next() != nil {}
      XCTFail("Expected streamOverflow")
    } catch TailscaleClientError.streamOverflow {
      // expected
    }
  }

  func testWatchIPNBusWithoutReconnectEndsOnConnectionDrop() async throws {
    let transport = MockTransport.scriptedStreams([
      [.jsonLine("{\"Version\":\"1.0\"}")],
      [.jsonLine("{\"Version\":\"2.0\"}")],
    ])
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .loopback(host: "127.0.0.1", port: 41320), authToken: "t",
        transport: transport))

    let stream = try await client.watchIPNBus()
    let (versions, error) = await Self.collectNotifyVersions(stream, stopAt: "never")

    XCTAssertNil(error, "A server close without a reconnect policy ends the stream normally")
    XCTAssertEqual(versions, ["1.0"])
  }

  #if os(macOS)
    // MARK: - Automatic source with counted discovery (macOS standalone layout)

    actor ProbeCounter {
      private(set) var count = 0
      func record() { count += 1 }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
      tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("watch-recovery-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
      if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private static func writeStandalone(in dir: URL, port: UInt16, token: String) throws {
      let ipnportURL = dir.appendingPathComponent("ipnport")
      try? FileManager.default.removeItem(at: ipnportURL)
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "\(port)")
      let tokenURL = dir.appendingPathComponent("sameuserproof-\(port)")
      try? FileManager.default.removeItem(at: tokenURL)
      try "\(token)\n".write(to: tokenURL, atomically: true, encoding: .utf8)
    }

    private func countedDiscovery(
      counter: ProbeCounter,
      probe: @escaping @Sendable (UInt16, String) -> Bool = { _, _ in true }
    ) -> LocalAPIDiscovery {
      LocalAPIDiscovery(
        environment: [:],
        fileExists: { _ in false },
        standaloneDirectoryOverride: tempDir,
        probeOverride: { port, token in
          let semaphore = DispatchSemaphore(value: 0)
          Task {
            await counter.record()
            semaphore.signal()
          }
          semaphore.wait()
          return probe(port, token)
        }
      )
    }

    private func assertSingleRediscoveryOnStaleCredential(
      status: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
      let port: UInt16 = 41250
      try Self.writeStandalone(in: tempDir, port: port, token: "token-rotated")
      let counter = ProbeCounter()
      let transport = RestartingDaemonTransport()
      await transport.setStreamHandler { index, config in
        if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
        if config.authToken == "token-stale" { return Self.statusOnly(status) }
        return Self.notifyStream(["new-1"], thenClose: false)
      }
      let config = TailscaleClientConfiguration(
        discovery: countedDiscovery(counter: counter),
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: port), authToken: "token-stale",
          capabilityVersion: 144),
        transport: transport
      )
      let client = TailscaleClient(configuration: config)

      let stream = try await client.watchIPNBusEvents(retryPolicy: Self.fastReconnect)
      let (versions, error) = await Self.collectVersions(stream, stopAt: "new-1")

      XCTAssertNil(error, "HTTP \(status) on reconnect should recover", file: file, line: line)
      XCTAssertEqual(versions, ["old-1", "new-1"], file: file, line: line)
      let probes = await counter.count
      XCTAssertEqual(probes, 1, "Exactly one rediscovery", file: file, line: line)
      let opens = await transport.opens
      XCTAssertEqual(opens.last?.token, "token-rotated", file: file, line: line)
    }

    func testReconnectRediscoversOnce_On401FromRestartedDaemon() async throws {
      try await assertSingleRediscoveryOnStaleCredential(status: 401)
    }

    func testReconnectRediscoversOnce_On403FromRestartedLoopbackDaemon() async throws {
      try await assertSingleRediscoveryOnStaleCredential(status: 403)
    }

    func testDaemonThatStaysDownIsBoundedAndPacedByRetryPolicy() async throws {
      let port: UInt16 = 41260
      try Self.writeStandalone(in: tempDir, port: port, token: "token-a")
      let counter = ProbeCounter()
      let transport = RestartingDaemonTransport()
      await transport.setStreamHandler { index, _ in
        if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(port)")
      }
      let config = TailscaleClientConfiguration(
        discovery: countedDiscovery(counter: counter, probe: { _, _ in false }),
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: port), authToken: "token-a",
          capabilityVersion: 144),
        transport: transport
      )
      let client = TailscaleClient(configuration: config)
      let policy = StreamRetryPolicy(
        maxAttempts: 3, initialDelay: .milliseconds(20), maxDelay: .milliseconds(40), jitter: 0)
      let minimumPacing = (0..<3).reduce(Duration.zero) { total, attempt in
        total + policy.delay(forAttempt: attempt)
      }

      let clock = ContinuousClock()
      let start = clock.now
      let stream = try await client.watchIPNBusEvents(retryPolicy: policy)
      let (versions, error) = await Self.collectVersions(stream, stopAt: "never")
      let elapsed = clock.now - start

      XCTAssertEqual(versions, ["old-1"])
      XCTAssertNil(error, "A stopped daemon is retryable; the stream ends when attempts run out")
      let opens = await transport.opens
      XCTAssertEqual(opens.count, 1 + 3, "Initial open plus maxAttempts reconnects")
      let probes = await counter.count
      XCTAssertEqual(probes, 3, "Exactly one rediscovery per reconnect attempt, never more")
      XCTAssertGreaterThanOrEqual(elapsed, minimumPacing, "Reconnects must follow policy delays")
    }

    func testUnaryRequestAndWatcherShareOneRediscovery() async throws {
      let oldPort: UInt16 = 41270
      let newPort: UInt16 = 41271
      try Self.writeStandalone(in: tempDir, port: newPort, token: "token-new")
      let counter = ProbeCounter()
      let probeStarted = expectation(description: "watcher started rediscovery")
      probeStarted.assertForOverFulfill = false
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }

      let transport = RestartingDaemonTransport()
      await transport.setStreamHandler { index, config in
        if Self.port(of: config.endpoint) == oldPort {
          if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
          throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(oldPort)")
        }
        return Self.notifyStream(["new-1"], thenClose: false)
      }
      await transport.setUnaryHandler { config in
        if Self.port(of: config.endpoint) == oldPort {
          throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(oldPort)")
        }
        return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
      }
      let config = TailscaleClientConfiguration(
        discovery: countedDiscovery(
          counter: counter,
          probe: { _, _ in
            probeStarted.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return true
          }),
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: oldPort), authToken: "token-old",
          capabilityVersion: 144),
        transport: transport
      )
      let client = TailscaleClient(configuration: config)

      let stream = try await client.watchIPNBusEvents(retryPolicy: Self.fastReconnect)
      let watcher = Task { await Self.collectVersions(stream, stopAt: "new-1") }

      await fulfillment(of: [probeStarted], timeout: 2)
      let unary = Task { try await client.status() }
      // Give the unary request time to reach the client while rediscovery is in flight.
      try await Task.sleep(for: .milliseconds(100))
      release.signal()

      let status = try await unary.value
      let (versions, error) = await watcher.value

      XCTAssertEqual(status.backendState, .running)
      XCTAssertNil(error)
      XCTAssertEqual(versions, ["old-1", "new-1"])
      let probes = await counter.count
      XCTAssertEqual(probes, 1, "Watcher and unary caller must share one rediscovery")
      let unaryCalls = await transport.unaryCalls
      XCTAssertEqual(unaryCalls.last?.token, "token-new")
    }

    // MARK: - Discovery metadata missing mid-restart

    func testReconnectRetriesWhileDiscoveryMetadataIsMissingThenRecovers() async throws {
      // The standalone directory starts empty, so rediscovery reports `.notInstalled`
      // until the third reconnect attempt writes `ipnport` and the proof file.
      let oldPort: UInt16 = 41330
      let newPort: UInt16 = 41331
      let dir: URL = tempDir
      let counter = ProbeCounter()
      let transport = RestartingDaemonTransport()
      await transport.setStreamHandler { index, config in
        if Self.port(of: config.endpoint) == oldPort {
          if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
          if index == 3 { try Self.writeStandalone(in: dir, port: newPort, token: "token-new") }
          throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(oldPort)")
        }
        return Self.notifyStream(["new-1"], thenClose: false)
      }
      let config = TailscaleClientConfiguration(
        discovery: countedDiscovery(counter: counter),
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: oldPort), authToken: "token-old",
          capabilityVersion: 144),
        transport: transport
      )
      let client = TailscaleClient(configuration: config)
      let policy = StreamRetryPolicy(
        maxAttempts: 5, initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), jitter: 0)

      let stream = try await client.watchIPNBusEvents(retryPolicy: policy)
      var labels: [String] = []
      var thrown: Error?
      do {
        for try await event in stream {
          switch event {
          case .notification(let notify): labels.append("notify:\(notify.version ?? "")")
          case .lifecycle(.retrying(let attempt, _)): labels.append("retrying:\(attempt)")
          case .lifecycle(.connected): labels.append("connected")
          case .lifecycle(.stateGap(let reason)): labels.append("gap:\(reason)")
          case .lifecycle(.disconnected): labels.append("disconnected")
          }
          if labels.last == "notify:new-1" || labels.count > 30 { break }
        }
      } catch {
        thrown = error
      }

      XCTAssertNil(thrown, "Missing discovery metadata on reconnect must be retried, not fatal")
      XCTAssertEqual(
        labels,
        [
          "connected", "notify:old-1", "disconnected", "retrying:1", "retrying:2", "retrying:3",
          "connected", "gap:reconnected", "notify:new-1",
        ])
      let last = await transport.opens.last
      XCTAssertEqual(last?.endpoint, .loopback(host: "127.0.0.1", port: newPort))
      XCTAssertEqual(last?.token, "token-new")
    }

    func testReconnectGivesUpPerPolicyWhenDiscoveryMetadataStaysMissing() async throws {
      let port: UInt16 = 41340
      let transport = RestartingDaemonTransport()
      await transport.setStreamHandler { index, _ in
        if index == 0 { return Self.notifyStream(["old-1"], thenClose: true) }
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(port)")
      }
      let config = TailscaleClientConfiguration(
        discovery: countedDiscovery(counter: ProbeCounter()),
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: port), authToken: "token-a",
          capabilityVersion: 144),
        transport: transport
      )
      let client = TailscaleClient(configuration: config)
      let policy = StreamRetryPolicy(
        maxAttempts: 3, initialDelay: .milliseconds(20), maxDelay: .milliseconds(40), jitter: 0)
      let minimumPacing = (0..<3).reduce(Duration.zero) { $0 + policy.delay(forAttempt: $1) }

      let clock = ContinuousClock()
      let start = clock.now
      let stream = try await client.watchIPNBusEvents(retryPolicy: policy)
      let (versions, error) = await Self.collectVersions(stream, stopAt: "never")
      let elapsed = clock.now - start

      XCTAssertEqual(versions, ["old-1"])
      XCTAssertNil(error, "Exhausted retries finish the stream")
      let opens = await transport.opens
      XCTAssertEqual(opens.count, 1 + 3, "Initial open plus maxAttempts reconnects")
      XCTAssertGreaterThanOrEqual(elapsed, minimumPacing, "Reconnects must follow policy delays")
    }

    func testInitialOpenSurfacesDiscoveryFailure() async throws {
      let port: UInt16 = 41350
      let transport = RestartingDaemonTransport()
      await transport.setStreamHandler { _, _ in
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:\(port)")
      }
      let config = TailscaleClientConfiguration(
        discovery: countedDiscovery(counter: ProbeCounter()),
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: port), authToken: "token-a",
          capabilityVersion: 144),
        transport: transport
      )
      let client = TailscaleClient(configuration: config)

      await assertThrowsErrorAsync(
        try await client.watchIPNBusEvents(retryPolicy: Self.fastReconnect)
      ) { error in
        guard case TailscaleClientError.discovery(.notInstalled) = error else {
          XCTFail("Expected discovery(.notInstalled), got \(error)")
          return
        }
      }
    }
  #endif
}
