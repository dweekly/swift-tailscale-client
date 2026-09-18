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

    /// Independent kill switch for the timeout tests: if deadline handling
    /// regresses, awaiting the broken operation would otherwise hang until
    /// the job-level CI timeout. Closing the server forces an EOF error
    /// instead, so the test fails promptly (wrong error + elapsed bound).
    private func armWatchdog(_ server: FaultUnixServer) -> Task<Void, any Error> {
      Task {
        try await Task.sleep(for: .seconds(5))
        server.stop()
      }
    }

    func testUnaryTimesOutWhenServerAcceptsButNeverReplies() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }
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
          case .endpointUnavailable(let endpoint, let feature) = clientError
        else {
          XCTFail("Expected endpointUnavailable for a 404 head, got \(error)")
          return
        }
        XCTAssertEqual(endpoint, "/localapi/v0/watch-ipn-bus")
        XCTAssertEqual(feature, "HasIPNBus")
      }
    }

    func testStreamingTimesOutWhenServerAcceptsButNeverSendsHead() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }
      let watchdog = armWatchdog(server)
      defer { watchdog.cancel() }
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

    // MARK: - Framing Fault Tests over Real Unix Socket (PR 04)

    func testUnaryThrowsOnTruncatedContentLengthBody() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\npartial",
          closeAfterWrite: true)
      ])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(2))

      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          XCTFail("Expected malformedResponse, got \(error)")
          return
        }
        XCTAssertEqual(detail, "Truncated Content-Length body")
      }
    }

    func testUnaryThrowsOnIncompleteChunkedBody() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n",
          closeAfterWrite: true)
      ])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(2))

      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          XCTFail("Expected malformedResponse, got \(error)")
          return
        }
        XCTAssertEqual(detail, "Incomplete chunked transfer")
      }
    }

    func testUnaryThrowsOnOversizedHTTPHeadOverSocket() async throws {
      let oversized = String(repeating: "A", count: 70 * 1024)
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nX-Oversized: \(oversized)\r\n\r\n{}",
          closeAfterWrite: true)
      ])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(2))

      await assertThrowsErrorAsync(try await client.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .malformedResponse(let detail) = transportError
        else {
          XCTFail("Expected malformedResponse, got \(error)")
          return
        }
        XCTAssertTrue(detail.contains("HTTP head exceeds"))
      }
    }

    // MARK: - Cooperative Cancellation Scenarios (< 1s Completion) (PR 05)

    func testCooperativeCancellationDuringReadHeaderTerminatesUnderOneSecond() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(10))

      let task = Task {
        try await client.status()
      }

      // Allow connect to complete and enter read loop
      try await Task.sleep(for: .milliseconds(50))
      let start = ContinuousClock.now
      task.cancel()

      _ = await task.result
      let elapsed = start.duration(to: .now)

      XCTAssertLessThan(
        elapsed, .seconds(1),
        "Cancelled task must exit within 1.0s, took \(elapsed)"
      )
    }

    func testCooperativeCancellationDuringStreamConsumptionTerminatesPromptly() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", closeAfterWrite: false)
      ])
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(10))

      let stream = try await client.watchIPNBus()
      let start = ContinuousClock.now

      let task = Task {
        for try await _ in stream {
          // never receives lines since server sends nothing after headers
        }
      }

      try await Task.sleep(for: .milliseconds(50))
      task.cancel()
      _ = await task.result

      let elapsed = start.duration(to: .now)
      XCTAssertLessThan(
        elapsed, .seconds(1),
        "Stream consumption cancellation must exit within 1.0s, took \(elapsed)"
      )
    }

    func testCooperativeCancellationDuringConnect() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      server.stop(keepSocketFile: true)
      defer { server.stop() }
      let client = makeClient(path: server.path, timeout: .seconds(5))

      let task = Task {
        try await client.status()
      }
      task.cancel()

      let start = ContinuousClock.now
      _ = await task.result
      let elapsed = start.duration(to: .now)

      XCTAssertLessThan(
        elapsed, .seconds(1),
        "Cancellation during connect must complete in < 1.0s, took \(elapsed)"
      )
    }

    // MARK: - 120-Cycle Zero Leak Verification (PR 05)

    func testAtLeast100ConnectCancelFailureCyclesReturnDescriptorsToBaseline() async throws {
      // Warm up: stabilize any lazy runtime/logging descriptors
      for _ in 0..<3 {
        let server = try FaultUnixServer(behaviors: [
          .respond("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", closeAfterWrite: true)
        ])
        let client = makeClient(path: server.path, timeout: .seconds(1))
        _ = try? await client.status()
        server.stop()
      }

      let baselineFDs = openFileDescriptorCount()
      let cycleCount = 120

      for i in 0..<cycleCount {
        let mode = i % 6
        switch mode {
        case 0:
          // Unary success
          let server = try FaultUnixServer(behaviors: [
            .respond("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", closeAfterWrite: true)
          ])
          let client = makeClient(path: server.path, timeout: .seconds(2))
          _ = try? await client.status()
          server.stop()

        case 1:
          // Missing socket (ENOENT)
          let client = makeClient(
            path: NSTemporaryDirectory() + "missing-\(UUID()).sock", timeout: .seconds(1))
          _ = try? await client.status()

        case 2:
          // Unserved socket (ECONNREFUSED)
          let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
          server.stop(keepSocketFile: true)
          let client = makeClient(path: server.path, timeout: .seconds(1))
          _ = try? await client.status()
          server.stop()

        case 3:
          // Silent server with caller cancellation
          let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
          let client = makeClient(path: server.path, timeout: .seconds(5))
          let task = Task { try await client.status() }
          try await Task.sleep(for: .milliseconds(20))
          task.cancel()
          _ = await task.result
          server.stop()

        case 4:
          // Streaming with consumer early break
          let body = "{\"Version\":\"v1\"}\n{\"Version\":\"v2\"}\n"
          let server = try FaultUnixServer(behaviors: [
            .respond(
              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" + body,
              closeAfterWrite: false)
          ])
          let client = makeClient(path: server.path, timeout: .seconds(2))
          if let stream = try? await client.watchIPNBus() {
            for try await _ in stream {
              break  // exit early
            }
          }
          server.stop()

        case 5:
          // Deadline timeout waiting for head
          let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
          let client = makeClient(path: server.path, timeout: .milliseconds(50))
          _ = try? await client.status()
          server.stop()

        default:
          break
        }
      }

      // Allow up to 2 seconds for any in-flight detached task defer cleanup blocks to settle
      let start = ContinuousClock.now
      while openFileDescriptorCount() > baselineFDs && ContinuousClock.now - start < .seconds(2) {
        try await Task.sleep(for: .milliseconds(50))
      }

      let finalFDs = openFileDescriptorCount()
      XCTAssertEqual(
        finalFDs, baselineFDs,
        "Descriptor leak detected after \(cycleCount) cycles: baseline was \(baselineFDs), final was \(finalFDs)"
      )
    }
  }

  // MARK: - Multi-Platform File Descriptor Inspection Helper

  #if canImport(Darwin)
    private struct ProcFDInfo {
      var procFD: Int32
      var procFDType: UInt32
    }
    @_silgen_name("proc_pidinfo")
    private func procPidInfo(
      _ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?,
      _ buffersize: Int32
    ) -> Int32
  #endif

  private func openFileDescriptorCount() -> Int {
    #if canImport(Darwin)
      let procPidListFDs: Int32 = 1
      let bufferSize = procPidInfo(getpid(), procPidListFDs, 0, nil, 0)
      if bufferSize > 0 {
        let capacity = Int(bufferSize) / MemoryLayout<ProcFDInfo>.stride
        var list = [ProcFDInfo](
          repeating: ProcFDInfo(procFD: 0, procFDType: 0), count: capacity)
        let actualBytes = procPidInfo(getpid(), procPidListFDs, 0, &list, bufferSize)
        if actualBytes > 0 {
          return Int(actualBytes) / MemoryLayout<ProcFDInfo>.stride
        }
      }
    #endif

    #if os(Linux)
      if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
        return entries.count
      }
    #endif

    let limit = min(getdtablesize(), 4096)
    var count = 0
    for fd in 0..<limit {
      if fcntl(fd, F_GETFD) >= 0 {
        count += 1
      }
    }
    return count
  }
#endif
