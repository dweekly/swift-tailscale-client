// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if canImport(Darwin) || os(Linux)
  /// A streaming response body ends where its framing says it ends: after
  /// `Content-Length` bytes, at the terminal chunk, or at EOF only when
  /// neither is present. Every server here holds its side of the connection
  /// open after writing (unless a test says otherwise), the way tailscaled
  /// does after rejecting a `watch-ipn-bus` request, so a client that waits
  /// for EOF instead of honoring `Content-Length` hangs until the watchdog
  /// closes the server and then fails the elapsed-time bound.
  final class StreamingBodyFramingSocketTests: XCTestCase {
    /// The tailscaled v1.104.7 rejection observed for a removed mask bit.
    private static let daemonMessage =
      "the NotifyRateLimit IPN bus subscription bit is no longer supported\n"

    private static func head(_ statusLine: String, _ headers: [String]) -> String {
      "HTTP/1.1 \(statusLine)\r\n" + headers.map { $0 + "\r\n" }.joined() + "\r\n"
    }

    private static let rejection =
      head(
        "400 Bad Request",
        [
          "Content-Type: text/plain; charset=utf-8",
          "Content-Length: \(daemonMessage.utf8.count)",
          "X-Content-Type-Options: nosniff",
        ]) + daemonMessage

    /// Must exceed `promptBound` so a hang shows up as a failed bound, not
    /// as a pass caused by the watchdog's EOF.
    private static let watchdogDelay: Duration = .seconds(3)
    private static let promptBound: Duration = .seconds(2)

    private func armWatchdog(_ server: FaultUnixServer) -> Task<Void, any Error> {
      Task {
        try await Task.sleep(for: Self.watchdogDelay)
        server.stop()
      }
    }

    private func makeClient(_ endpoint: TailscaleEndpoint) -> TailscaleClient {
      TailscaleClient(
        configuration: TailscaleClientConfiguration(
          endpoint: endpoint,
          authToken: nil,
          capabilityVersion: 1,
          requestTimeout: .seconds(10),
          transport: URLSessionTailscaleTransport()))
    }

    private func drain(_ response: StreamingResponse) async throws -> [String] {
      var lines: [String] = []
      for try await line in response.body {
        lines.append(String(decoding: line, as: UTF8.self))
      }
      return lines
    }

    // MARK: - Unix socket transport

    func testRejectionWithContentLengthOnHeldConnectionEndsPromptlyAndClosesSocket() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(Self.rejection, closeAfterWrite: false)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }

      // The server holds only its listener now; once the client connects it
      // also holds the accepted descriptor, which it keeps open throughout.
      let baseline = openDescriptorCount()
      let start = ContinuousClock.now
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      XCTAssertEqual(response.statusCode, 400)
      let lines = try await drain(response)
      XCTAssertLessThan(start.duration(to: .now), Self.promptBound)
      XCTAssertEqual(lines, [String(Self.daemonMessage.dropLast())])

      // Client descriptor closed: only the server's accepted descriptor remains.
      let expected = baseline + 1
      let settle = ContinuousClock.now
      while openDescriptorCount() > expected, settle.duration(to: .now) < .seconds(1) {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(
        openDescriptorCount(), expected,
        "Client socket must be closed once the framed body is complete")
    }

    func testZeroContentLengthRejectionOnHeldConnectionEndsPromptly() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          Self.head("500 Internal Server Error", ["Content-Length: 0"]), closeAfterWrite: false)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }

      let start = ContinuousClock.now
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      XCTAssertEqual(response.statusCode, 500)
      let lines = try await drain(response)
      XCTAssertLessThan(start.duration(to: .now), Self.promptBound)
      XCTAssertEqual(lines, [])
    }

    func testNoContentStatusOnHeldConnectionEndsPromptly() async throws {
      // 204 has no body by definition, whatever the headers say.
      let server = try FaultUnixServer(behaviors: [
        .respond(Self.head("204 No Content", []), closeAfterWrite: false)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }

      let start = ContinuousClock.now
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      let lines = try await drain(response)
      XCTAssertLessThan(start.duration(to: .now), Self.promptBound)
      XCTAssertEqual(lines, [])
    }

    func testBodyShorterThanContentLengthAtEOFIsTypedFramingError() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          Self.head("400 Bad Request", ["Content-Length: 50"]) + "only twenty bytes...",
          closeAfterWrite: true)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }

      let start = ContinuousClock.now
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      do {
        let lines = try await drain(response)
        XCTFail("A truncated Content-Length body must fail, got \(lines)")
      } catch TailscaleTransportError.malformedResponse(let detail) {
        XCTAssertEqual(detail, "Truncated Content-Length body")
      }
      XCTAssertLessThan(start.duration(to: .now), Self.promptBound)
    }

    func testSuccessWithContentLengthOnHeldConnectionDeliversLinesThenEnds() async throws {
      let body = "{\"Version\":\"t1\"}\n{\"Version\":\"t2\"}\n"
      // Bytes after the declared body belong to no response and are ignored.
      let server = try FaultUnixServer(behaviors: [
        .respond(
          Self.head(
            "200 OK", ["Content-Type: application/json", "Content-Length: \(body.utf8.count)"])
            + body + "{\"Version\":\"ignored\"}\n",
          closeAfterWrite: false)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }

      let start = ContinuousClock.now
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      let lines = try await drain(response)
      XCTAssertLessThan(start.duration(to: .now), Self.promptBound)
      XCTAssertEqual(lines, ["{\"Version\":\"t1\"}", "{\"Version\":\"t2\"}"])
    }

    func testInvalidContentLengthOnStreamingHeadIsTypedFramingError() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(Self.head("400 Bad Request", ["Content-Length: -3"]), closeAfterWrite: false)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }

      do {
        let response = try await UnixSocketTransport(path: server.path).sendStreaming(
          TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
        XCTFail("An invalid Content-Length must fail, got HTTP \(response.statusCode)")
      } catch TailscaleTransportError.malformedResponse(let detail) {
        XCTAssertEqual(detail, "Invalid Content-Length header: '-3'")
      }
    }

    func testChunkedStreamOnHeldConnectionEndsAtTerminalChunk() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          Self.head("200 OK", ["Transfer-Encoding: chunked", "Content-Length: 3"])
            + "8\r\none\ntwo\n\r\n0\r\n\r\n", closeAfterWrite: false)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }

      let start = ContinuousClock.now
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      let lines = try await drain(response)
      XCTAssertLessThan(start.duration(to: .now), Self.promptBound)
      XCTAssertEqual(lines, ["one", "two"])
    }

    // MARK: - Public entry points

    private func assertPromptRejection(
      _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
      let start = ContinuousClock.now
      do {
        try await operation()
        XCTFail("Expected the 400 rejection to throw", file: file, line: line)
      } catch let error as TailscaleClientError {
        guard case .unexpectedStatus(let code, let body, let endpoint) = error else {
          XCTFail("Expected unexpectedStatus, got \(error)", file: file, line: line)
          return
        }
        XCTAssertEqual(code, 400, file: file, line: line)
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus", file: file, line: line)
        XCTAssertEqual(
          String(decoding: body, as: UTF8.self), String(Self.daemonMessage.dropLast()),
          file: file, line: line)
        XCTAssertEqual(
          error.bodyPreview, String(Self.daemonMessage.dropLast()), file: file, line: line)
      } catch {
        XCTFail("Expected TailscaleClientError, got \(error)", file: file, line: line)
      }
      XCTAssertLessThan(start.duration(to: .now), Self.promptBound, file: file, line: line)
    }

    func testWatchIPNBusReportsRejectionPromptly() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(Self.rejection, closeAfterWrite: false)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }
      let client = makeClient(.unixSocket(path: server.path))

      await assertPromptRejection { _ = try await client.watchIPNBus() }
    }

    func testWatchIPNBusEventsReportsRejectionPromptly() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(Self.rejection, closeAfterWrite: false)
      ])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }
      let client = makeClient(.unixSocket(path: server.path))

      await assertPromptRejection {
        _ = try await client.watchIPNBusEvents(retryPolicy: .none)
      }
    }

    // MARK: - Loopback TCP (URLSession) transport

    #if !canImport(FoundationNetworking)
      func testLoopbackTransportReportsRejectionPromptly() async throws {
        let server = try FaultUnixServer(loopbackBehaviors: [
          .respond(Self.rejection, closeAfterWrite: false)
        ])
        defer { server.stop() }
        let watchdog = armWatchdog(server)
        defer { watchdog.cancel() }
        let port = try XCTUnwrap(server.port)
        let client = makeClient(.loopback(host: "127.0.0.1", port: port))

        await assertPromptRejection { _ = try await client.watchIPNBus() }
      }
    #endif

    // MARK: - Descriptor counting

    private func openDescriptorCount() -> Int {
      #if os(Linux)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
          return entries.count
        }
      #endif
      let limit = min(getdtablesize(), 4096)
      var count = 0
      for fd in 0..<limit where fcntl(fd, F_GETFD) >= 0 {
        count += 1
      }
      return count
    }
  }
#endif
