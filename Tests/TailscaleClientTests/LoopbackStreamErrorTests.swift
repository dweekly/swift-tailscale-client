// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

#if !canImport(FoundationNetworking)
  /// Failures on the loopback (URLSession) streaming path are reported as the
  /// same `TailscaleTransportError` cases the unary path reports, so a watch
  /// recognizes a restarted daemon's refused old port as a connect-stage
  /// failure and rediscovers. Everything here runs through the real
  /// `URLSessionTailscaleTransport` against real loopback sockets; the
  /// mock-transport versions of these scenarios are in
  /// `WatchReconnectRecoveryTests`.
  final class LoopbackStreamErrorTests: XCTestCase {
    private static let chunkedHead =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
      + "Transfer-Encoding: chunked\r\n\r\n"

    private static func line(_ version: String) -> String {
      let text = "{\"Version\":\"\(version)\"}\n"
      return String(text.utf8.count, radix: 16) + "\r\n" + text + "\r\n"
    }

    /// Sends one notification and then holds the connection open, quiet,
    /// until the server stops.
    private static func daemon(sending version: String) -> FaultUnixServer.Behavior {
      .respondThenLater(chunkedHead + line(version), after: 30, "")
    }

    private static let fastReconnect = StreamRetryPolicy(
      maxAttempts: 3, initialDelay: .milliseconds(20), maxDelay: .milliseconds(40), jitter: 0)

    /// A loopback port with nothing listening: bound once, then closed.
    private static func refusingPort() throws -> UInt16 {
      let server = try FaultUnixServer(loopbackBehaviors: [.acceptThenSilence])
      let port = try XCTUnwrap(server.port)
      server.stop()
      return port
    }

    private static func port(_ server: FaultUnixServer) throws -> UInt16 {
      try XCTUnwrap(server.port)
    }

    private static func basicAuthorization(_ token: String) -> String {
      "Basic " + Data(":\(token)".utf8).base64EncodedString()
    }

    /// The client configuration a discovered standalone daemon produces:
    /// automatic source, whose rediscovery returns `newPort` and `newToken`.
    private static func automaticConfiguration(
      port: UInt16, token: String, newPort: UInt16, newToken: String
    ) -> TailscaleClientConfiguration {
      let discovery = LocalAPIDiscovery(environment: [
        "TAILSCALE_LOCALAPI_PORT": String(newPort),
        "TAILSCALE_LOCALAPI_AUTHKEY": newToken,
      ])
      return TailscaleClientConfiguration(
        discovery: discovery,
        result: .init(
          endpoint: .loopback(host: "127.0.0.1", port: port), authToken: token,
          capabilityVersion: 1),
        requestTimeout: .seconds(5),
        transport: URLSessionTailscaleTransport())
    }

    private func armWatchdog(_ servers: [FaultUnixServer]) -> Task<Void, any Error> {
      Task {
        try await Task.sleep(for: .seconds(8))
        for server in servers { server.stop() }
      }
    }

    private func transportError(_ error: any Error) -> TailscaleTransportError? {
      if case .transport(let transportError) = error as? TailscaleClientError {
        return transportError
      }
      return nil
    }

    // MARK: - (a) Refused port: streaming open matches the unary path

    func testRefusedPortIsConnectStageForWatchOpenAndUnaryAlike() async throws {
      let port = try Self.refusingPort()
      let client = TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: .loopback(host: "127.0.0.1", port: port), authToken: nil,
          capabilityVersion: 1, requestTimeout: .seconds(5),
          transport: URLSessionTailscaleTransport()))

      var unaryError: (any Error)?
      do { _ = try await client.status() } catch { unaryError = error }
      var watchError: (any Error)?
      do {
        _ = try await client.watchIPNBusEvents(options: [.initialState], retryPolicy: .none)
      } catch { watchError = error }

      let unaryTransport = unaryError.flatMap(transportError)
      let watchTransport = watchError.flatMap(transportError)
      XCTAssertNotNil(
        unaryTransport,
        "Unary must throw TailscaleClientError.transport, got \(String(describing: unaryError))")
      XCTAssertNotNil(
        watchTransport,
        "Watch open must throw TailscaleClientError.transport, got \(String(describing: watchError))"
      )
      XCTAssertTrue(
        unaryTransport.map(TailscaleClient.isConnectStageError) ?? false,
        "Unary refusal must be connect-stage, got \(String(describing: unaryTransport))")
      XCTAssertTrue(
        watchTransport.map(TailscaleClient.isConnectStageError) ?? false,
        "Watch-open refusal must be connect-stage, got \(String(describing: watchTransport))")
      XCTAssertEqual(
        watchTransport.map { String(describing: $0) },
        unaryTransport.map { String(describing: $0) })
    }

    // MARK: - (b) Events stream follows a restarted daemon to its new port

    func testWatchEventsRediscoversRestartedDaemonOnNewPort() async throws {
      let oldDaemon = try FaultUnixServer(loopbackBehaviors: [Self.daemon(sending: "old-1")])
      defer { oldDaemon.stop() }
      let newDaemon = try FaultUnixServer(loopbackBehaviors: [Self.daemon(sending: "new-1")])
      defer { newDaemon.stop() }
      let watchdog = armWatchdog([oldDaemon, newDaemon])
      defer { watchdog.cancel() }
      let newPort = try Self.port(newDaemon)
      let client = TailscaleClient(
        configuration: Self.automaticConfiguration(
          port: try Self.port(oldDaemon), token: "token-old", newPort: newPort,
          newToken: "token-new"))

      let stream = try await client.watchIPNBusEvents(
        options: [.initialState], retryPolicy: Self.fastReconnect)
      var labels: [String] = []
      var failure: (any Error)?
      do {
        for try await event in stream {
          switch event {
          case .notification(let notify):
            labels.append("notify:\(notify.version ?? "")")
            // The daemon restarts: its old port now refuses connections.
            if notify.version == "old-1" { oldDaemon.stop() }
          case .lifecycle(.connected):
            labels.append("connected")
          case .lifecycle(.retrying):
            labels.append("retrying")
          case .lifecycle(.stateGap(let reason)):
            labels.append("gap:\(reason)")
          case .lifecycle(.disconnected):
            labels.append("disconnected")
          }
          if labels.last == "notify:new-1" || labels.count > 20 { break }
        }
      } catch {
        failure = error
      }

      XCTAssertNil(failure, "The watch must recover, not end with \(String(describing: failure))")
      XCTAssertEqual(
        labels,
        [
          "connected", "notify:old-1", "disconnected", "retrying", "connected",
          "gap:reconnected", "notify:new-1",
        ])
      XCTAssertEqual(newDaemon.acceptedConnections, 1)
      XCTAssertTrue(
        newDaemon.receivedRequests.first?.contains(Self.basicAuthorization("token-new")) ?? false,
        "The reconnect must carry the rediscovered token")
      XCTAssertEqual(client.configuration.endpoint, .loopback(host: "127.0.0.1", port: newPort))
      XCTAssertEqual(client.configuration.authToken, "token-new")
    }

    // MARK: - (c) Simple stream does the same

    func testWatchIPNBusRediscoversRestartedDaemonOnNewPort() async throws {
      let oldDaemon = try FaultUnixServer(loopbackBehaviors: [Self.daemon(sending: "old-1")])
      defer { oldDaemon.stop() }
      let newDaemon = try FaultUnixServer(loopbackBehaviors: [Self.daemon(sending: "new-1")])
      defer { newDaemon.stop() }
      let watchdog = armWatchdog([oldDaemon, newDaemon])
      defer { watchdog.cancel() }
      let newPort = try Self.port(newDaemon)
      let client = TailscaleClient(
        configuration: Self.automaticConfiguration(
          port: try Self.port(oldDaemon), token: "token-old", newPort: newPort,
          newToken: "token-new"))

      let stream = try await client.watchIPNBus(
        options: [.initialState],
        reconnect: IPNBusReconnectPolicy(
          maxAttempts: 3, initialDelay: .milliseconds(20), maxDelay: .milliseconds(40)))
      var versions: [String?] = []
      var failure: (any Error)?
      do {
        for try await notify in stream {
          versions.append(notify.version)
          if notify.version == "old-1" { oldDaemon.stop() }
          if notify.version == "new-1" || versions.count > 10 { break }
        }
      } catch {
        failure = error
      }

      XCTAssertNil(failure, "The watch must recover, not end with \(String(describing: failure))")
      XCTAssertEqual(versions, ["old-1", "new-1"])
      XCTAssertEqual(newDaemon.acceptedConnections, 1)
      XCTAssertEqual(client.configuration.endpoint, .loopback(host: "127.0.0.1", port: newPort))
      XCTAssertEqual(client.configuration.authToken, "token-new")
    }

    // MARK: - (d) A pinned configuration never rediscovers

    func testPinnedWatchRetriesRefusedPortWithoutRediscovery() async throws {
      let oldDaemon = try FaultUnixServer(loopbackBehaviors: [Self.daemon(sending: "old-1")])
      defer { oldDaemon.stop() }
      // A daemon a rediscovery could have found; a pinned watch must not reach it.
      let otherDaemon = try FaultUnixServer(loopbackBehaviors: [Self.daemon(sending: "other")])
      defer { otherDaemon.stop() }
      let watchdog = armWatchdog([oldDaemon, otherDaemon])
      defer { watchdog.cancel() }
      let endpoint = TailscaleEndpoint.loopback(host: "127.0.0.1", port: try Self.port(oldDaemon))
      let client = TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: endpoint, authToken: "pinned-token", capabilityVersion: 1,
          requestTimeout: .seconds(5), transport: URLSessionTailscaleTransport(),
          endpointSource: .pinned(endpoint)))

      let stream = try await client.watchIPNBusEvents(
        options: [.initialState], retryPolicy: Self.fastReconnect)
      var versions: [String?] = []
      var retries = 0
      var failure: (any Error)?
      do {
        for try await event in stream {
          if let notify = event.notification {
            versions.append(notify.version)
            if notify.version == "old-1" { oldDaemon.stop() }
          }
          if case .retrying = event.lifecycle { retries += 1 }
        }
      } catch {
        failure = error
      }

      XCTAssertNil(failure, "Retryable refusals exhaust the policy and end the stream")
      XCTAssertEqual(versions, ["old-1"])
      XCTAssertEqual(retries, 3)
      XCTAssertEqual(otherDaemon.acceptedConnections, 0)
      XCTAssertEqual(client.configuration.endpoint, endpoint)
      XCTAssertEqual(client.configuration.authToken, "pinned-token")
    }
  }
#endif
