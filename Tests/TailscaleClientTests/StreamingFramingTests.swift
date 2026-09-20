// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import Testing

@testable import TailscaleClient

#if canImport(Darwin) || os(Linux)
  struct StreamingFramingTests {
    @Test(arguments: ["5\r\nabc", "4\r\nabc\n\r\n", "4\r\nabc\n\r\n0\r\nX-Test: value\r\n"])
    func truncatedChunkedStreamThrows(body: String) async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + body, closeAfterWrite: true)
      ])
      defer { server.stop() }
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      do {
        for try await _ in response.body {}
        Issue.record("A truncated chunked stream must fail, including after complete lines")
      } catch TailscaleTransportError.malformedResponse(let detail) {
        #expect(detail == "Incomplete chunked transfer")
      }
    }

    @Test(arguments: [false, true])
    func completeStreamPreservesFinalLine(chunked: Bool) async throws {
      let header = chunked ? "Transfer-Encoding: chunked\r\n" : ""
      let body = chunked ? "7\r\none\ntwo\r\n0\r\nX-Test: value\r\n\r\n" : "one\ntwo"
      let server = try FaultUnixServer(behaviors: [
        .respond("HTTP/1.1 200 OK\r\n" + header + "\r\n" + body, closeAfterWrite: true)
      ])
      defer { server.stop() }
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      var lines: [String] = []
      for try await line in response.body { lines.append(String(decoding: line, as: UTF8.self)) }
      #expect(lines == ["one", "two"])
    }

    @Test
    func slowConsumerReceivesEntireStreamBeyondBufferCapacity() async throws {
      // More than four times the transport's 256 KiB high-water mark and
      // four times the old 256-element dropping buffer.
      let lines = (0..<1024).map { "\($0):" + String(repeating: "x", count: 1024) }
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\n\r\n" + lines.joined(separator: "\n") + "\n", closeAfterWrite: true)
      ])
      defer { server.stop() }
      let response = try await UnixSocketTransport(path: server.path).sendStreaming(
        TailscaleRequest(path: "/localapi/v0/watch-ipn-bus"), capabilityVersion: 1)
      // Deliberately stall this consumer while the socket reader fills its queue.
      try await Task.sleep(for: .milliseconds(100))
      var received: [String] = []
      for try await line in response.body {
        received.append(String(decoding: line, as: UTF8.self))
        if received.count.isMultiple(of: 64) { try await Task.sleep(for: .milliseconds(2)) }
      }
      #expect(received == lines)
    }
  }
#endif
