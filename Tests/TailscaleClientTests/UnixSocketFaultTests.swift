// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

#if canImport(Darwin) || os(Linux)
  /// Hostile-transport tests against a real Unix socket: these are the
  /// regressions for the deadline and connect-before-return fixes — a mock
  /// transport would pass with or without those fixes, so a real socket is
  /// the only honest verifier.
  final class UnixSocketFaultTests: XCTestCase {

    private func makeClient(path: String, timeout: Duration?) -> TailscaleClient {
      let configuration = TailscaleClientConfiguration(
        endpoint: .unixSocket(path: path),
        authToken: nil,
        capabilityVersion: 1,
        requestTimeout: timeout,
        transport: URLSessionTailscaleTransport())
      return TailscaleClient(configuration: configuration)
    }

    func testUnaryTimesOutWhenServerAcceptsButNeverReplies() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .milliseconds(700))

      let start = ContinuousClock.now
      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .timeout = clientError
        else {
          XCTFail("Expected .timeout, got \(error)")
          return
        }
      }
      let elapsed = start.duration(to: .now)
      XCTAssertLessThan(
        elapsed, .seconds(5),
        "The deadline must actually interrupt the blocking read, not wait for EOF")
    }

    func testStreamingThrowsWhenSocketIsMissing() async {
      let client = makeClient(
        path: NSTemporaryDirectory() + "definitely-missing.sock", timeout: .seconds(2))
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport = clientError
        else {
          XCTFail("watchIPNBus must throw before returning a stream; got \(error)")
          return
        }
      }
    }

    func testStreamingThrowsWhenNothingIsListening() async throws {
      // A socket file with no listener behind it: connect() gets ECONNREFUSED.
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      server.stop(keepSocketFile: true)
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(2))

      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport = clientError
        else {
          XCTFail("Expected a transport error before the stream exists, got \(error)")
          return
        }
      }
    }

    func testStreamingThrowsOnNon200ResponseHead() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
          closeAfterWrite: true)
      ])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(2))

      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          XCTFail("Expected malformedResponse for a non-200 head, got \(error)")
          return
        }
        XCTAssertTrue(detail.contains("404"), "Detail should name the status: \(detail)")
      }
    }

    func testStreamingTimesOutWhenServerAcceptsButNeverSendsHead() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .milliseconds(700))

      let start = ContinuousClock.now
      await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .timeout = clientError
        else {
          XCTFail("Expected .timeout waiting for the response head, got \(error)")
          return
        }
      }
      XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    func testStreamingDeliversLinesFromRealSocket() async throws {
      // Positive control: the same real-socket path end-to-end.
      let body = "{\"Version\":\"t1\"}\n{\"Version\":\"t2\"}\n"
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" + body,
          closeAfterWrite: true)
      ])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(2))

      var versions: [String] = []
      for try await notify in try await client.watchIPNBus() {
        if let version = notify.version { versions.append(version) }
      }
      XCTAssertEqual(versions, ["t1", "t2"])
    }
  }
#endif
