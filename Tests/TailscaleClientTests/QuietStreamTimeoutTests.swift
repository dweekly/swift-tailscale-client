// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

#if canImport(Darwin) || os(Linux)
  /// `requestTimeout` bounds getting a response to a streaming request, not
  /// how long an established stream may stay quiet. A daemon that is logged
  /// out, stopped, or has nothing to report can send nothing on the IPN bus
  /// for minutes, and the watch must stay open through that silence. Every
  /// test here runs over a real socket (loopback TCP through URLSession, or a
  /// Unix socket) with a `requestTimeout` shorter than the silence.
  final class QuietStreamTimeoutTests: XCTestCase {
    private static let requestTimeout: Duration = .seconds(1)
    /// Seconds of silence between the first and second line: three times
    /// `requestTimeout`.
    private static let silence: TimeInterval = 3
    /// Extra time allowed past an expected moment for scheduling on CI.
    private static let tolerance: Duration = .milliseconds(900)

    private static func chunk(_ text: String) -> String {
      String(text.utf8.count, radix: 16) + "\r\n" + text + "\r\n"
    }

    private static let chunkedHead =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
      + "Transfer-Encoding: chunked\r\n\r\n"

    /// One NDJSON line, `silence` seconds of nothing on a held-open
    /// connection, then a second line.
    private static func quietThenLate(after delay: TimeInterval = silence)
      -> FaultUnixServer.Behavior
    {
      .respondThenLater(
        chunkedHead + chunk("{\"Version\":\"first\"}\n"),
        after: delay,
        chunk("{\"Version\":\"late\"}\n"))
    }

    private func makeClient(_ endpoint: TailscaleEndpoint, timeout: Duration?) -> TailscaleClient {
      TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: endpoint,
          authToken: nil,
          capabilityVersion: 1,
          requestTimeout: timeout,
          transport: URLSessionTailscaleTransport()))
    }

    private func makeConfiguration(_ endpoint: TailscaleEndpoint, timeout: Duration?)
      -> TailscaleClientConfiguration
    {
      TailscaleClientConfiguration(
        endpoint: endpoint,
        authToken: nil,
        capabilityVersion: 1,
        requestTimeout: timeout,
        transport: URLSessionTailscaleTransport())
    }

    /// Closes the server after `seconds` so a regression fails on the
    /// assertions instead of hanging the job.
    private func armWatchdog(_ server: FaultUnixServer, seconds: Int = 8) -> Task<Void, any Error> {
      Task {
        try await Task.sleep(for: .seconds(seconds))
        server.stop()
      }
    }

    /// Events with the time they arrived, measured from the recorder's creation.
    private actor EventRecorder {
      let start = ContinuousClock.now
      private(set) var events: [(IPNBusEvent, Duration)] = []
      private(set) var failure: (any Error)?
      private(set) var finished = false

      func record(_ event: IPNBusEvent) {
        events.append((event, start.duration(to: .now)))
      }

      func finish(_ error: (any Error)?) {
        failure = error
        finished = true
      }

      var notifications: [(String?, Duration)] {
        events.compactMap { event, at in event.notification.map { ($0.version, at) } }
      }

      var lifecycles: [IPNBusLifecycle] { events.compactMap { $0.0.lifecycle } }

      var isDoneOrHasTwoLines: Bool { finished || notifications.count >= 2 }
    }

    private func consume(
      _ stream: AsyncThrowingStream<IPNBusEvent, Error>, into recorder: EventRecorder
    ) -> Task<Void, Never> {
      Task {
        do {
          for try await event in stream { await recorder.record(event) }
          await recorder.finish(nil)
        } catch {
          await recorder.finish(error)
        }
      }
    }

    /// Polls until `condition` holds or `limit` passes.
    private func waitUntil(
      _ limit: Duration, _ condition: @Sendable () async -> Bool
    ) async throws {
      let deadline = ContinuousClock.now + limit
      while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
      }
    }

    /// Watches with `watchIPNBusEvents` and asserts the late line arrives on
    /// the same connection with no disconnect, retry, or state gap.
    private func assertQuietWatchSurvives(
      _ client: TailscaleClient,
      server: FaultUnixServer,
      retryPolicy: StreamRetryPolicy,
      file: StaticString = #filePath,
      line: UInt = #line
    ) async throws {
      let recorder = EventRecorder()
      let stream = try await client.watchIPNBusEvents(
        options: [.initialState], retryPolicy: retryPolicy)
      let consumer = consume(stream, into: recorder)
      defer { consumer.cancel() }

      let silence = Duration.seconds(Self.silence)
      try await waitUntil(silence + Self.tolerance) {
        await recorder.isDoneOrHasTwoLines
      }

      let notifications = await recorder.notifications
      let lifecycles = await recorder.lifecycles
      let failure = await recorder.failure
      XCTAssertNil(failure, "The quiet watch must not fail", file: file, line: line)
      XCTAssertEqual(
        notifications.map(\.0), ["first", "late"],
        "The watch must deliver the line sent after the silence", file: file, line: line)
      if notifications.count == 2 {
        XCTAssertGreaterThanOrEqual(
          notifications[1].1, silence - .milliseconds(100), file: file, line: line)
      }
      XCTAssertEqual(lifecycles, [.connected], file: file, line: line)
      XCTAssertEqual(server.acceptedConnections, 1, "No reconnect", file: file, line: line)
      XCTAssertEqual(
        server.peerClosedConnections, 0, "The client must not close a quiet stream",
        file: file, line: line)
    }

    private func assertOpenTimesOut(
      _ client: TailscaleClient, file: StaticString = #filePath, line: UInt = #line
    ) async {
      let start = ContinuousClock.now
      await assertThrowsErrorAsync(
        try await client.watchIPNBusEvents(options: [.initialState], retryPolicy: .none)
      ) { error in
        guard case .timeout(let endpoint) = error as? TailscaleClientError else {
          XCTFail("Expected .timeout opening the watch, got \(error)", file: file, line: line)
          return
        }
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus", file: file, line: line)
      }
      let elapsed = start.duration(to: .now)
      XCTAssertGreaterThanOrEqual(
        elapsed, Self.requestTimeout - .milliseconds(50), file: file, line: line)
      XCTAssertLessThan(elapsed, Self.requestTimeout + Self.tolerance, file: file, line: line)
    }

    /// Opens a watch, reads its first line, cancels the consumer during the
    /// silence, and asserts the server sees the connection closed promptly.
    private func assertCancellingQuietConsumerClosesConnection(
      _ endpoint: (FaultUnixServer) throws -> TailscaleEndpoint,
      server: FaultUnixServer,
      file: StaticString = #filePath,
      line: UInt = #line
    ) async throws {
      let client = makeClient(try endpoint(server), timeout: .seconds(10))
      let stream = try await client.watchIPNBus(options: [.initialState])
      let consumer = Task {
        var versions: [String?] = []
        for try await notify in stream { versions.append(notify.version) }
        return versions
      }
      try await waitUntil(.seconds(2)) { server.acceptedConnections == 1 }
      // Give the first line time to arrive so the stream is established and quiet.
      try await Task.sleep(for: .milliseconds(200))

      let start = ContinuousClock.now
      consumer.cancel()
      _ = await consumer.result
      try await waitUntil(.seconds(2)) { server.peerClosedConnections == 1 }
      let elapsed = start.duration(to: .now)
      XCTAssertEqual(server.peerClosedConnections, 1, file: file, line: line)
      XCTAssertLessThan(elapsed, .seconds(1), file: file, line: line)
    }

    // MARK: - Loopback TCP (URLSession) transport

    #if !canImport(FoundationNetworking)
      private static func loopback(_ server: FaultUnixServer) throws -> TailscaleEndpoint {
        .loopback(host: "127.0.0.1", port: try XCTUnwrap(server.port))
      }

      func testLoopbackQuietWatchStaysOpenPastRequestTimeout() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [Self.quietThenLate()])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let client = makeClient(try Self.loopback(server), timeout: Self.requestTimeout)

        try await assertQuietWatchSurvives(client, server: server, retryPolicy: .none)
      }

      func testLoopbackQuietWatchWithRetryPolicyReportsNoGap() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [Self.quietThenLate()])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let client = makeClient(try Self.loopback(server), timeout: Self.requestTimeout)

        try await assertQuietWatchSurvives(
          client, server: server, retryPolicy: StreamRetryPolicy(initialDelay: .milliseconds(50)))
      }

      func testLoopbackQuietWatchIPNBusWithReconnectDoesNotReconnect() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [Self.quietThenLate()])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let client = makeClient(try Self.loopback(server), timeout: Self.requestTimeout)

        let stream = try await client.watchIPNBus(
          options: [.initialState],
          reconnect: IPNBusReconnectPolicy(initialDelay: .milliseconds(50)))
        var versions: [String?] = []
        for try await notify in stream {
          versions.append(notify.version)
          if versions.count == 2 { break }
        }
        // A reconnect would replay "first" from the next connection.
        XCTAssertEqual(versions, ["first", "late"])
        XCTAssertEqual(server.acceptedConnections, 1)
        XCTAssertEqual(server.peerClosedConnections, 0)
      }

      func testLoopbackWatchOpenWithoutResponseHeadTimesOut() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [.acceptThenSilence])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let client = makeClient(try Self.loopback(server), timeout: Self.requestTimeout)

        await assertOpenTimesOut(client)
      }

      /// Without `TailscaleClient`'s deadline around it, the transport itself
      /// still bounds waiting for the response head by `requestTimeout`, and
      /// reports it the way the unary path reports its timeout:
      /// `networkFailure(URLError(.timedOut))`.
      func testLoopbackTransportStreamingOpenWithoutResponseHeadTimesOut() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [.acceptThenSilence])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let configuration = makeConfiguration(
          try Self.loopback(server), timeout: Self.requestTimeout)
        let transport = URLSessionTailscaleTransport()

        let start = ContinuousClock.now
        await assertThrowsErrorAsync(
          try await transport.sendStreaming(
            TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), configuration: configuration)
        ) { error in
          guard case .networkFailure(let underlying) = error as? TailscaleTransportError,
            (underlying as? URLError)?.code == .timedOut
          else {
            XCTFail("Expected networkFailure(URLError.timedOut), got \(error)")
            return
          }
        }
        let elapsed = start.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, Self.requestTimeout - .milliseconds(50))
        XCTAssertLessThan(elapsed, Self.requestTimeout + Self.tolerance)
      }

      /// The request's own timeout interval takes precedence over the
      /// session's `timeoutIntervalForRequest`, so a caller-supplied session
      /// with a short value does not end a quiet stream either.
      func testLoopbackQuietStreamOutlivesShortSessionRequestTimeout() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [Self.quietThenLate()])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let configuration = TailscaleClientConfiguration(
          endpoint: try Self.loopback(server),
          authToken: nil,
          capabilityVersion: 1,
          requestTimeout: Self.requestTimeout,
          transport: URLSessionTailscaleTransport(session: session))

        let response = try await configuration.transport.sendStreaming(
          TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), configuration: configuration)
        var lines: [String] = []
        for try await line in response.body {
          lines.append(String(decoding: line, as: UTF8.self))
          if lines.count == 2 { break }
        }
        XCTAssertEqual(lines, ["{\"Version\":\"first\"}", "{\"Version\":\"late\"}"])
        XCTAssertEqual(server.peerClosedConnections, 0)
      }

      /// What still bounds a stream on this transport: the session's
      /// `timeoutIntervalForResource` (7 days for `URLSession.shared`) ends a
      /// stream that has been open that long, however healthy.
      func testLoopbackSessionResourceTimeoutStillEndsStream() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [Self.quietThenLate()])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let configuration = TailscaleClientConfiguration(
          endpoint: try Self.loopback(server),
          authToken: nil,
          capabilityVersion: 1,
          requestTimeout: .seconds(10),
          transport: URLSessionTailscaleTransport(session: session))

        let start = ContinuousClock.now
        let response = try await configuration.transport.sendStreaming(
          TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), configuration: configuration)
        var lines: [String] = []
        do {
          for try await line in response.body {
            lines.append(String(decoding: line, as: UTF8.self))
          }
          XCTFail("Expected the resource timeout to end the stream")
        } catch {
          guard case .networkFailure(let underlying) = error as? TailscaleTransportError,
            (underlying as? URLError)?.code == .timedOut
          else {
            XCTFail("Expected networkFailure(URLError.timedOut), got \(error)")
            return
          }
        }
        XCTAssertEqual(lines, ["{\"Version\":\"first\"}"])
        XCTAssertLessThan(start.duration(to: .now), .seconds(1.5) + Self.tolerance)
      }

      func testLoopbackUnaryWithoutResponseTimesOut() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [.acceptThenSilence])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let client = makeClient(try Self.loopback(server), timeout: Self.requestTimeout)

        let start = ContinuousClock.now
        await assertThrowsErrorAsync(try await client.status()) { error in
          guard let clientError = error as? TailscaleClientError else {
            XCTFail("Expected TailscaleClientError, got \(error)")
            return
          }
          switch clientError {
          case .timeout:
            break
          case .transport(.networkFailure(let underlying))
          where (underlying as? URLError)?.code == .timedOut:
            break
          default:
            XCTFail("Expected a timeout, got \(clientError)")
          }
        }
        let elapsed = start.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, Self.requestTimeout - .milliseconds(50))
        XCTAssertLessThan(elapsed, Self.requestTimeout + Self.tolerance)
      }

      func testLoopbackCancellingQuietConsumerClosesConnection() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [Self.quietThenLate(after: 10)])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }

        try await assertCancellingQuietConsumerClosesConnection(Self.loopback, server: server)
      }
    #endif

    // MARK: - Unix socket transport

    func testUnixQuietWatchStaysOpenPastRequestTimeout() async throws {
      let server = try FaultUnixServer(behaviors: [Self.quietThenLate()])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }
      let client = makeClient(.unixSocket(path: server.path), timeout: Self.requestTimeout)

      try await assertQuietWatchSurvives(client, server: server, retryPolicy: .none)
    }

    func testUnixWatchOpenWithoutResponseHeadTimesOut() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }
      let client = makeClient(.unixSocket(path: server.path), timeout: Self.requestTimeout)

      await assertOpenTimesOut(client)
    }

    func testUnixCancellingQuietConsumerClosesConnection() async throws {
      let server = try FaultUnixServer(behaviors: [Self.quietThenLate(after: 10)])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }

      try await assertCancellingQuietConsumerClosesConnection(
        { .unixSocket(path: $0.path) }, server: server)
    }
  }
#endif
