// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// IPN bus watches against daemons that reject `NotifyWatchOpt.obsolete`
/// (upstream `ObsoleteNotifyInitialNetMap` and `ObsoleteNotifyRateLimit`) with
/// HTTP 400, as Tailscale v1.104.7 was observed to do, and against daemons that
/// accept them, as v1.102.2 does. Everything goes through `watchIPNBus` and
/// `watchIPNBusEvents`.
final class WatchObsoleteOptionsTests: XCTestCase {

  // MARK: - Harness

  static let rateLimitMessage =
    "the NotifyRateLimit IPN bus subscription bit is no longer supported"
  static let netMapMessage =
    "the NotifyInitialNetMap IPN bus subscription bit is no longer supported; "
    + "seed from NotifyInitialStatus instead"

  /// Counts body streams that were terminated (finished, cancelled, or released).
  final class TerminationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return _count
    }
    func increment() {
      lock.lock()
      _count += 1
      lock.unlock()
    }
  }

  enum Answer: Sendable {
    /// 200 with one notification per version; closes afterwards if `close`.
    case notifications([String], close: Bool)
    /// A status with a text body. `keepOpen` models a daemon that keeps the
    /// connection alive after the body, so reading to EOF never returns.
    case status(Int, String, keepOpen: Bool)
    /// The connection is refused.
    case refuse
  }

  /// Streaming transport that records each open's mask and endpoint and
  /// answers through `decide`.
  actor MaskDaemon: TailscaleTransport {
    private(set) var masks: [UInt64] = []
    private(set) var endpoints: [TailscaleEndpoint] = []
    let decide: @Sendable (Int, UInt64, TailscaleClientConfiguration) -> Answer
    let terminations: TerminationCounter

    init(
      terminations: TerminationCounter = TerminationCounter(),
      decide: @escaping @Sendable (Int, UInt64, TailscaleClientConfiguration) -> Answer
    ) {
      self.decide = decide
      self.terminations = terminations
    }

    func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration) async throws
      -> TailscaleResponse
    {
      throw TailscaleTransportError.unimplemented
    }

    func sendStreaming(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
      async throws -> StreamingResponse
    {
      let maskText = request.queryItems.first(where: { $0.name == "mask" })?.value ?? ""
      let mask = UInt64(maskText) ?? .max
      masks.append(mask)
      endpoints.append(configuration.endpoint)
      let counter = terminations
      switch decide(masks.count - 1, mask, configuration) {
      case .refuse:
        throw TailscaleTransportError.connectionRefused(endpoint: "test")
      case .notifications(let versions, let close):
        return StreamingResponse(
          statusCode: 200,
          body: AsyncThrowingStream { continuation in
            for version in versions {
              continuation.yield(Data("{\"Version\":\"\(version)\"}".utf8))
            }
            if close { continuation.finish() }
          })
      case .status(let code, let message, let keepOpen):
        return StreamingResponse(
          statusCode: code,
          headers: ["Content-Type": "text/plain"],
          body: AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in counter.increment() }
            continuation.yield(Data(message.utf8))
            if !keepOpen { continuation.finish() }
          })
      }
    }
  }

  /// Answers like `ipn.ValidateNotifyWatchOpt` in v1.104.7: bit 8, then bit 3.
  static func answerLikeV1104(_ mask: UInt64, versions: [String] = ["1.104.7"], close: Bool = false)
    -> Answer
  {
    if mask & (1 << 8) != 0 { return .status(400, rateLimitMessage, keepOpen: true) }
    if mask & (1 << 3) != 0 { return .status(400, netMapMessage, keepOpen: true) }
    return .notifications(versions, close: close)
  }

  /// Answers like v1.102.2: bit 8 together with any of bits 12-15 is rejected.
  static func answerLikeV1102(_ mask: UInt64) -> Answer {
    if mask & (1 << 8) != 0, mask & (0xF << 12) != 0 {
      return .status(
        400,
        "NotifyRateLimit is incompatible with new-style IPN bus subscription bits "
          + "ipn.NotifyInitialStatus",
        keepOpen: true)
    }
    return .notifications(["1.102.2"], close: false)
  }

  static func pinnedClient(_ transport: any TailscaleTransport) -> TailscaleClient {
    TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .loopback(host: "127.0.0.1", port: 41300),
        authToken: "token",
        capabilityVersion: 152,
        requestTimeout: .seconds(5),
        transport: transport))
  }

  static let nwxOptions: NotifyWatchOpt = [
    .initialState, .initialHealthState, .rateLimit, .noPrivateKeys,
  ]

  static let fastReconnect = StreamRetryPolicy(
    maxAttempts: nil, initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), jitter: 0)

  /// The first notification's version, or nil if none arrives within two seconds.
  static func firstVersion(_ stream: AsyncThrowingStream<IPNNotify, Error>) async throws
    -> String?
  {
    try await withThrowingTaskGroup(of: String?.self) { group in
      group.addTask {
        for try await notify in stream { return notify.version }
        return nil
      }
      group.addTask {
        try await Task.sleep(for: .seconds(2))
        return nil
      }
      let first = try await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  /// Collects notification versions and the terminating error, stopping after
  /// `count` notifications or two seconds.
  static func collect(_ stream: AsyncThrowingStream<IPNBusEvent, Error>, count: Int) async
    -> (versions: [String], error: Error?)
  {
    await withTaskGroup(of: ([String], Error?)?.self) { group in
      group.addTask {
        var versions: [String] = []
        do {
          for try await event in stream {
            guard case .notification(let notify) = event else { continue }
            versions.append(notify.version ?? "")
            if versions.count == count { break }
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

  static func assertUnexpectedStatus400(
    _ error: Error?, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .unexpectedStatus(let code, _, let endpoint)? = error as? TailscaleClientError
    else {
      return XCTFail(
        "expected unexpectedStatus(400), got \(String(describing: error))",
        file: file, line: line)
    }
    XCTAssertEqual(code, 400, file: file, line: line)
    XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus", file: file, line: line)
  }

  // MARK: - Rejecting daemon

  func testDefaultWatchDropsObsoleteOptionsAndRemembersForLaterWatches() async throws {
    let terminations = TerminationCounter()
    let daemon = MaskDaemon(terminations: terminations) { _, mask, _ in Self.answerLikeV1104(mask) }
    let client = Self.pinnedClient(daemon)

    let first = try await Self.firstVersion(client.watchIPNBus())
    XCTAssertEqual(first, "1.104.7")
    var masks = await daemon.masks
    XCTAssertEqual(masks, [387, 131])
    XCTAssertEqual(NotifyWatchOpt.default.rawValue, 387)

    let second = try await Self.firstVersion(client.watchIPNBus())
    XCTAssertEqual(second, "1.104.7")
    masks = await daemon.masks
    XCTAssertEqual(
      masks, [387, 131, 131], "a later watch must send one request without bits 3 and 8")
  }

  func testRejectedResponseIsReleasedUnreadExactlyOnce() async throws {
    let terminations = TerminationCounter()
    let daemon = MaskDaemon(terminations: terminations) { _, mask, _ in Self.answerLikeV1104(mask) }
    let client = Self.pinnedClient(daemon)

    // The rejected body never finishes, so a read to EOF would time out here.
    let first = try await Self.firstVersion(client.watchIPNBus())
    XCTAssertEqual(first, "1.104.7")

    let deadline = ContinuousClock.now + .seconds(2)
    while terminations.count == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(terminations.count, 1, "the 400 body must be terminated exactly once")
  }

  func testNWXOptionsReconnectWithReducedMaskInOneRequest() async throws {
    let daemon = MaskDaemon { index, mask, _ in
      // The first accepted connection closes after one notification.
      Self.answerLikeV1104(mask, versions: [index <= 1 ? "first" : "second"], close: index <= 1)
    }
    let client = Self.pinnedClient(daemon)

    let stream = try await client.watchIPNBus(
      options: Self.nwxOptions,
      reconnect: IPNBusReconnectPolicy(
        maxAttempts: 3, initialDelay: .milliseconds(10), maxDelay: .milliseconds(20)))
    var versions: [String] = []
    for try await notify in stream {
      versions.append(notify.version ?? "")
      if versions.count == 2 { break }
    }

    XCTAssertEqual(versions, ["first", "second"])
    let masks = await daemon.masks
    let reduced = Self.nwxOptions.subtracting([.rateLimit]).rawValue
    XCTAssertEqual(masks, [Self.nwxOptions.rawValue, reduced, reduced])
  }

  func testAllInitialAgainstRejectingDaemon() async throws {
    let daemon = MaskDaemon { _, mask, _ in Self.answerLikeV1104(mask) }
    let client = Self.pinnedClient(daemon)

    let first = try await Self.firstVersion(client.watchIPNBus(options: .allInitial))
    XCTAssertEqual(first, "1.104.7")
    let masks = await daemon.masks
    XCTAssertEqual(masks, [1262, 1254])
  }

  func testRateLimitWithInitialStatusRecoversOnIncompatibleBitsRejection() async throws {
    let daemon = MaskDaemon { _, mask, _ in Self.answerLikeV1102(mask) }
    let client = Self.pinnedClient(daemon)

    let first = try await Self.firstVersion(
      client.watchIPNBus(options: [.rateLimit, .initialStatus]))
    XCTAssertEqual(first, "1.102.2")
    let masks = await daemon.masks
    XCTAssertEqual(masks, [16640, 16384])
  }

  // MARK: - Accepting daemon

  func testAcceptingDaemonReceivesExactCallerMaskInOneRequest() async throws {
    let daemon = MaskDaemon { _, _, _ in .notifications(["1.102.2"], close: false) }
    let client = Self.pinnedClient(daemon)

    let first = try await Self.firstVersion(client.watchIPNBus())
    XCTAssertEqual(first, "1.102.2")
    let nwx = try await Self.firstVersion(client.watchIPNBus(options: Self.nwxOptions))
    XCTAssertEqual(nwx, "1.102.2")
    let masks = await daemon.masks
    XCTAssertEqual(masks, [387, Self.nwxOptions.rawValue])
    XCTAssertNotEqual(masks[0] & (1 << 8), 0)
  }

  // MARK: - 400s the retry does not resolve

  func testBadRequestWithoutObsoleteOptionsFailsInitialOpen() async throws {
    let daemon = MaskDaemon { _, _, _ in .status(400, "bad mask", keepOpen: false) }
    let client = Self.pinnedClient(daemon)

    var thrown: Error?
    do {
      _ = try await client.watchIPNBus(options: [.initialState])
    } catch {
      thrown = error
    }
    Self.assertUnexpectedStatus400(thrown)
    if case .unexpectedStatus(_, let body, _)? = thrown as? TailscaleClientError {
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "bad mask")
    }
    let masks = await daemon.masks
    XCTAssertEqual(masks, [2])
  }

  func testBadRequestOnReconnectEndsStreamWithoutFurtherAttempts() async throws {
    let daemon = MaskDaemon { index, _, _ in
      index == 0
        ? .notifications(["first"], close: true) : .status(400, "bad mask", keepOpen: false)
    }
    let client = Self.pinnedClient(daemon)

    let stream = try await client.watchIPNBusEvents(
      options: [.initialState], retryPolicy: Self.fastReconnect)
    let (versions, error) = await Self.collect(stream, count: 2)

    XCTAssertEqual(versions, ["first"])
    Self.assertUnexpectedStatus400(error)
    try await Task.sleep(for: .milliseconds(100))
    let masks = await daemon.masks
    XCTAssertEqual(masks, [2, 2], "a 400 must not be retried")
  }

  func testStillRejectedWithoutObsoleteOptionsFailsAfterTwoRequests() async throws {
    let daemon = MaskDaemon { _, mask, _ in
      .status(400, "rejected \(mask)", keepOpen: mask & NotifyWatchOpt.obsolete.rawValue != 0)
    }
    let client = Self.pinnedClient(daemon)

    var thrown: Error?
    do {
      _ = try await client.watchIPNBus()
    } catch {
      thrown = error
    }
    Self.assertUnexpectedStatus400(thrown)
    var masks = await daemon.masks
    XCTAssertEqual(masks, [387, 131])

    // Nothing was learned, so the next watch asks for the caller's options again.
    _ = try? await client.watchIPNBus()
    masks = await daemon.masks
    XCTAssertEqual(masks, [387, 131, 387, 131])
  }

  func testStillRejectedOnReconnectEndsStreamAfterTwoRequests() async throws {
    let daemon = MaskDaemon { index, mask, _ in
      if index == 0 { return .notifications(["first"], close: true) }
      return .status(400, "rejected", keepOpen: mask & NotifyWatchOpt.obsolete.rawValue != 0)
    }
    let client = Self.pinnedClient(daemon)

    let stream = try await client.watchIPNBusEvents(retryPolicy: Self.fastReconnect)
    let (versions, error) = await Self.collect(stream, count: 2)

    XCTAssertEqual(versions, ["first"])
    Self.assertUnexpectedStatus400(error)
    try await Task.sleep(for: .milliseconds(100))
    let masks = await daemon.masks
    XCTAssertEqual(masks, [387, 387, 131])
  }

  // MARK: - Composition with rediscovery

  func testObsoleteOptionsRejectionOnRediscoveredEndpointRecovers() async throws {
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "41311",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-new",
      ]
    )
    let daemon = MaskDaemon { _, mask, config in
      if case .loopback(_, 41310) = config.endpoint { return .refuse }
      return Self.answerLikeV1104(mask)
    }
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        discovery: discovery,
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: 41310), authToken: "token-old",
          capabilityVersion: 152),
        transport: daemon))

    let first = try await Self.firstVersion(client.watchIPNBus())
    XCTAssertEqual(first, "1.104.7")
    let masks = await daemon.masks
    let endpoints = await daemon.endpoints
    XCTAssertEqual(masks, [387, 387, 131])
    XCTAssertEqual(
      endpoints,
      [
        .loopback(host: "127.0.0.1", port: 41310),
        .loopback(host: "127.0.0.1", port: 41311),
        .loopback(host: "127.0.0.1", port: 41311),
      ])
  }

  func testRediscoveryAfterObsoleteOptionsRetryStillRuns() async throws {
    // The options retry is answered 401 by a daemon whose token rotated; the
    // retry's own rediscovery step recovers it.
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "41320",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-new",
      ]
    )
    let daemon = MaskDaemon { index, mask, config in
      if index == 1 { return .status(401, "unauthorized", keepOpen: false) }
      return Self.answerLikeV1104(mask)
    }
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        discovery: discovery,
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: 41320), authToken: "token-old",
          capabilityVersion: 152),
        transport: daemon))

    let first = try await Self.firstVersion(client.watchIPNBus())
    XCTAssertEqual(first, "1.104.7")
    let masks = await daemon.masks
    XCTAssertEqual(masks, [387, 131, 131])
    XCTAssertEqual(client.configuration.authToken, "token-new")
  }

  // MARK: - Classification

  func testStatusClassificationTable() {
    func classify(_ code: Int) -> StreamErrorClassification {
      StreamRetryPolicy.classify(
        TailscaleClientError.unexpectedStatus(code: code, body: Data(), endpoint: "/test"))
    }
    XCTAssertEqual(classify(400), .fatal)
    XCTAssertEqual(classify(401), .fatal)
    XCTAssertEqual(classify(403), .fatal)
    XCTAssertEqual(classify(404), .fatal)
    XCTAssertEqual(classify(409), .retryable)
    XCTAssertEqual(classify(500), .retryable)
    XCTAssertEqual(classify(502), .retryable)
    XCTAssertEqual(classify(503), .retryable)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.permissionDenied(body: Data(), endpoint: "/test")), .fatal)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.endpointUnavailable(endpoint: "/test", feature: nil)), .fatal)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.rateLimited(retryAfterSeconds: 1, body: Data(), endpoint: "/test")),
      .retryable)
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleClientError.timeout(endpoint: "/test")), .retryable)
    XCTAssertEqual(
      StreamRetryPolicy.classify(TailscaleTransportError.connectionRefused(endpoint: "/test")),
      .retryable)
    XCTAssertEqual(
      StreamRetryPolicy.classify(
        TailscaleClientError.transport(
          .networkFailure(underlying: URLError(.networkConnectionLost)))),
      .retryable)
  }

  // MARK: - Real Unix socket

  #if canImport(Darwin) || os(Linux)
    /// The daemon answers the first connection with a 400 that carries
    /// `Content-Length` and keeps the connection open, as v1.104.7 does. The
    /// client must open a second connection and close the first.
    func testRejectedConnectionIsClosedOnRealSocket() async throws {
      let body = Self.rateLimitMessage + "\n"
      let rejection =
        "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\n"
        + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
      let accepted =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"Version\":\"1.104.7\"}\n"
      let server = try FaultUnixServer(behaviors: [
        .respond(rejection, closeAfterWrite: false),
        .respond(accepted, closeAfterWrite: false),
      ])
      defer { server.stop() }
      let client = TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: .unixSocket(path: server.path),
          authToken: nil,
          capabilityVersion: 152,
          requestTimeout: .seconds(3),
          transport: URLSessionTailscaleTransport()))

      let baseline = openSocketDescriptorCount()
      let watch = Task { () -> String? in
        let stream = try await client.watchIPNBus()
        for try await notify in stream {
          // Hold the stream open until cancelled, after the first notification.
          if notify.version != nil {
            try await Task.sleep(for: .seconds(30))
          }
        }
        return nil
      }

      // Open: the server keeps both accepted descriptors; the client keeps only
      // the second connection once it has released the rejected one.
      let deadline = ContinuousClock.now + .seconds(4)
      while openSocketDescriptorCount() != baseline + 3, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(openSocketDescriptorCount(), baseline + 3)

      watch.cancel()
      _ = try? await watch.value
      let closeDeadline = ContinuousClock.now + .seconds(4)
      while openSocketDescriptorCount() != baseline + 2, ContinuousClock.now < closeDeadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(openSocketDescriptorCount(), baseline + 2)
    }
  #endif
}
