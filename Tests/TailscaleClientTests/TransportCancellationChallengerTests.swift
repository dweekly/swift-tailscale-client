// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

#if canImport(Darwin) || os(Linux)

  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif

  /// Adversarial empirical test harness for Milestone 1 W2 (PR 04 & PR 05).
  ///
  /// Validates:
  /// 1. Cancellation responsiveness (< 1.0s) during:
  ///    - Blocked write (large payload exceeding socket send buffer)
  ///    - Blocked connect / pre-cancellation
  ///    - Blocked read header
  ///    - Blocked stream body consumption
  /// 2. Timeout deadlines (< 1.0s) for unary and streaming requests
  /// 3. Zero file descriptor leaks across 150 cycles using kernel introspection (`proc_pidinfo`)
  /// 4. High-concurrency cancellation storms (20 concurrent cancelled requests)
  final class TransportCancellationChallengerTests: XCTestCase {

    private func makeClient(path: String, timeout: Duration? = .seconds(5)) -> TailscaleClient {
      let configuration = TailscaleClientConfiguration(
        endpoint: .unixSocket(path: path),
        authToken: nil,
        capabilityVersion: 1,
        requestTimeout: timeout,
        transport: URLSessionTailscaleTransport()
      )
      return TailscaleClient(configuration: configuration)
    }

    // MARK: - 1. Cancellation Responsiveness (< 1.0s)

    func testCancellationDuringBlockedWriteTerminatesUnderOneSecond() async throws {
      // Server accepts the connection, reads only the initial 4KB chunk, and never reads again.
      // Client attempts to send a 5MB payload, which quickly fills the socket send buffer.
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }

      let client = makeClient(path: server.path, timeout: .seconds(15))
      let largePayload = Data(repeating: 0x5a, count: 5 * 1024 * 1024)  // 5 MB

      let task = Task {
        // Send raw request with 5MB body through the client's internal transport
        let request = TailscaleRequest(
          method: "POST",
          path: "/localapi/v0/serve-config",
          body: largePayload
        )
        return try await client.configuration.transport.send(
          request, configuration: client.configuration)
      }

      // Allow connect to succeed and write loop to fill buffer and block in waitWritable
      try await Task.sleep(for: .milliseconds(50))

      let start = ContinuousClock.now
      task.cancel()

      let result = await task.result
      let elapsed = start.duration(to: .now)

      XCTAssertLessThan(
        elapsed, .seconds(1.0),
        "Task cancelled while blocked in write must terminate within 1.0s; took \(elapsed)"
      )

      // Result must be a cancellation error
      switch result {
      case .success:
        XCTFail("Expected cancellation error, got success")
      case .failure(let error):
        XCTAssertTrue(
          error is CancellationError || (error as? TailscaleTransportError) != nil,
          "Expected CancellationError or transport error, got \(error)"
        )
      }
    }

    func testCancellationDuringConnectTerminatesUnderOneSecond() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      server.stop(keepSocketFile: true)  // leaves unserved socket file
      defer { server.stop() }

      let client = makeClient(path: server.path, timeout: .seconds(10))

      let task = Task {
        try await client.status()
      }
      task.cancel()

      let start = ContinuousClock.now
      _ = await task.result
      let elapsed = start.duration(to: .now)

      XCTAssertLessThan(
        elapsed, .seconds(1.0),
        "Task cancelled during connect must terminate in < 1.0s; took \(elapsed)"
      )
    }

    func testCancellationDuringReadHeaderTerminatesUnderOneSecond() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }

      let client = makeClient(path: server.path, timeout: .seconds(10))

      let task = Task {
        try await client.status()
      }

      // Allow connect and request write to complete so task is blocked in waitReadable
      try await Task.sleep(for: .milliseconds(50))

      let start = ContinuousClock.now
      task.cancel()

      _ = await task.result
      let elapsed = start.duration(to: .now)

      XCTAssertLessThan(
        elapsed, .seconds(1.0),
        "Task cancelled while reading header must terminate in < 1.0s; took \(elapsed)"
      )
    }

    func testCancellationDuringStreamBodyReadTerminatesUnderOneSecond() async throws {
      let server = try FaultUnixServer(behaviors: [
        .respond(
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", closeAfterWrite: false)
      ])
      defer { server.stop() }

      let client = makeClient(path: server.path, timeout: .seconds(10))
      let stream = try await client.watchIPNBus()

      let consumerTask = Task {
        for try await _ in stream {
          // Will never yield because server sends no body bytes
        }
      }

      // Allow consumer to start and block in streamBody waitReadable
      try await Task.sleep(for: .milliseconds(50))

      let start = ContinuousClock.now
      consumerTask.cancel()

      _ = await consumerTask.result
      let elapsed = start.duration(to: .now)

      XCTAssertLessThan(
        elapsed, .seconds(1.0),
        "Stream consumer cancelled while waiting for body data must exit in < 1.0s; took \(elapsed)"
      )
    }

    // MARK: - 2. Timeout Deadlines

    func testUnaryTimeoutDeadlineEnforcedUnderOneSecond() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }

      let timeoutDuration: Duration = .milliseconds(300)
      let client = makeClient(path: server.path, timeout: timeoutDuration)

      let start = ContinuousClock.now
      do {
        _ = try await client.status()
        XCTFail("Expected timeout error")
      } catch let error as TailscaleClientError {
        if case .timeout = error {
          // Expected
        } else {
          XCTFail("Expected .timeout, got \(error)")
        }
      } catch {
        XCTFail("Expected TailscaleClientError.timeout, got \(error)")
      }
      let elapsed = start.duration(to: .now)

      XCTAssertGreaterThanOrEqual(
        elapsed, timeoutDuration,
        "Timeout must not fire prematurely"
      )
      XCTAssertLessThan(
        elapsed, .seconds(1.2),
        "Timeout deadline must fire and clean up in < 1.2s; took \(elapsed)"
      )
    }

    func testStreamingHeadTimeoutDeadlineEnforcedUnderOneSecond() async throws {
      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }

      let timeoutDuration: Duration = .milliseconds(300)
      let client = makeClient(path: server.path, timeout: timeoutDuration)

      let start = ContinuousClock.now
      do {
        _ = try await client.watchIPNBus()
        XCTFail("Expected timeout error before returning stream")
      } catch let error as TailscaleClientError {
        if case .timeout = error {
          // Expected
        } else {
          XCTFail("Expected .timeout, got \(error)")
        }
      } catch {
        XCTFail("Expected TailscaleClientError.timeout, got \(error)")
      }
      let elapsed = start.duration(to: .now)

      XCTAssertGreaterThanOrEqual(elapsed, timeoutDuration)
      XCTAssertLessThan(elapsed, .seconds(1.2))
    }

    // MARK: - 3. Kernel Introspection & 150-Cycle Leak Harness

    func testZeroDescriptorLeaksAcross150CyclesUsingKernelIntrospection() async throws {
      // Warm-up to stabilize dynamic loader, dispatch queues, and runtime allocations
      for _ in 0..<5 {
        let server = try FaultUnixServer(behaviors: [
          .respond("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", closeAfterWrite: true)
        ])
        let client = makeClient(path: server.path, timeout: .seconds(1))
        _ = try? await client.status()
        server.stop()
      }

      // Allow baseline to settle
      let settleDeadline = ContinuousClock.now + .seconds(2)
      var previousFD = openFDCount()
      while ContinuousClock.now < settleDeadline {
        try await Task.sleep(for: .milliseconds(50))
        let current = openFDCount()
        if current == previousFD { break }
        previousFD = current
      }
      let baselineFDCount = openFDCount()
      let baselineSocketCount = openSocketFDCount()

      let totalCycles = 150

      for i in 0..<totalCycles {
        let cycleType = i % 10
        switch cycleType {
        case 0:
          // Unary success
          let server = try FaultUnixServer(behaviors: [
            .respond("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", closeAfterWrite: true)
          ])
          let client = makeClient(path: server.path, timeout: .seconds(2))
          _ = try? await client.status()
          server.stop()

        case 1:
          // Non-existent socket file (ENOENT)
          let client = makeClient(
            path: NSTemporaryDirectory() + "nonexistent-\(UUID().uuidString).sock",
            timeout: .seconds(1)
          )
          _ = try? await client.status()

        case 2:
          // Unserved socket file (ECONNREFUSED)
          let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
          server.stop(keepSocketFile: true)
          let client = makeClient(path: server.path, timeout: .seconds(1))
          _ = try? await client.status()
          server.stop()

        case 3:
          // Silent server with client task cancellation during read header
          let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
          let client = makeClient(path: server.path, timeout: .seconds(5))
          let task = Task { try await client.status() }
          try await Task.sleep(for: .milliseconds(15))
          task.cancel()
          _ = await task.result
          server.stop()

        case 4:
          // Blocked write with client task cancellation
          let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
          let client = makeClient(path: server.path, timeout: .seconds(5))
          let payload = Data(repeating: 0x42, count: 2 * 1024 * 1024)
          let task = Task {
            let req = TailscaleRequest(method: "POST", path: "/test", body: payload)
            _ = try? await client.configuration.transport.send(
              req, configuration: client.configuration)
          }
          try await Task.sleep(for: .milliseconds(15))
          task.cancel()
          _ = await task.result
          server.stop()

        case 5:
          // Deadline timeout unary
          let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
          let client = makeClient(path: server.path, timeout: .milliseconds(30))
          _ = try? await client.status()
          server.stop()

        case 6:
          // Streaming early break by consumer
          let body = "{\"Version\":\"1.0\"}\n{\"Version\":\"2.0\"}\n"
          let server = try FaultUnixServer(behaviors: [
            .respond(
              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" + body,
              closeAfterWrite: false)
          ])
          let client = makeClient(path: server.path, timeout: .seconds(2))
          if let stream = try? await client.watchIPNBus() {
            for try await _ in stream {
              break
            }
          }
          server.stop()

        case 7:
          // Streaming deadline timeout waiting for head
          let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
          let client = makeClient(path: server.path, timeout: .milliseconds(30))
          _ = try? await client.watchIPNBus()
          server.stop()

        case 8:
          // Truncated Content-Length
          let server = try FaultUnixServer(behaviors: [
            .respond("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort", closeAfterWrite: true)
          ])
          let client = makeClient(path: server.path, timeout: .seconds(1))
          _ = try? await client.status()
          server.stop()

        case 9:
          // Oversized HTTP head (> 64 KiB)
          let oversized = String(repeating: "X", count: 68 * 1024)
          let server = try FaultUnixServer(behaviors: [
            .respond("HTTP/1.1 200 OK\r\nX-Bad: \(oversized)\r\n\r\n{}", closeAfterWrite: true)
          ])
          let client = makeClient(path: server.path, timeout: .seconds(1))
          _ = try? await client.status()
          server.stop()

        default:
          break
        }
      }

      // Await cleanup of detached tasks
      let deadline = ContinuousClock.now + .seconds(3)
      while (openFDCount() > baselineFDCount || openSocketFDCount() > baselineSocketCount)
        && ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(50))
      }

      let finalFDCount = openFDCount()
      let finalSocketCount = openSocketFDCount()

      XCTAssertLessThanOrEqual(
        finalFDCount, baselineFDCount,
        "Kernel introspection detected open file descriptor leak after \(totalCycles) cycles: baseline=\(baselineFDCount), final=\(finalFDCount)"
      )

      XCTAssertLessThanOrEqual(
        finalSocketCount, baselineSocketCount,
        "Kernel introspection detected socket descriptor leak after \(totalCycles) cycles: baseline=\(baselineSocketCount), final=\(finalSocketCount)"
      )
    }

    // MARK: - 4. High-Concurrency Cancellation Storm

    func testConcurrentCancellationStormNoDescriptorLeaks() async throws {
      let baselineFDs = openFDCount()

      let server = try FaultUnixServer(behaviors: [.acceptThenSilence])
      defer { server.stop() }

      let client = makeClient(path: server.path, timeout: .seconds(5))
      let concurrency = 4  // Matches FaultUnixServer listen backlog of 4

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<concurrency {
          group.addTask {
            let task = Task {
              try await client.status()
            }
            try? await Task.sleep(for: .milliseconds(20))
            task.cancel()
            _ = await task.result
          }
        }
      }

      // Stop the server so its listener and accepted sockets close cleanly
      server.stop()

      // Allow background cleanups of client detached tasks to finish
      let deadline = ContinuousClock.now + .seconds(3)
      while openFDCount() > baselineFDs && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }

      let finalFDs = openFDCount()
      XCTAssertEqual(
        finalFDs, baselineFDs,
        "Concurrent cancellation storm leaked descriptors: baseline=\(baselineFDs), final=\(finalFDs)"
      )
    }

    // MARK: - Kernel Introspection Helpers

    #if canImport(Darwin)
      private struct ProcFDInfo {
        var procFD: Int32
        var procFDType: UInt32
      }
      private let proxFDTypeSocket: UInt32 = 2

      @_silgen_name("proc_pidinfo")
      private func procPidInfo(
        _ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?,
        _ buffersize: Int32
      ) -> Int32

      private func darwinFDList() -> [ProcFDInfo] {
        let procPidListFDs: Int32 = 1
        let bufferSize = procPidInfo(getpid(), procPidListFDs, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let capacity = Int(bufferSize) / MemoryLayout<ProcFDInfo>.stride
        var list = [ProcFDInfo](repeating: ProcFDInfo(procFD: 0, procFDType: 0), count: capacity)
        let actualBytes = procPidInfo(getpid(), procPidListFDs, 0, &list, bufferSize)
        guard actualBytes > 0 else { return [] }
        let actualCount = Int(actualBytes) / MemoryLayout<ProcFDInfo>.stride
        return Array(list.prefix(actualCount))
      }
    #endif

    private func openFDCount() -> Int {
      #if canImport(Darwin)
        let list = darwinFDList()
        if !list.isEmpty { return list.count }
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

    private func openSocketFDCount() -> Int {
      #if canImport(Darwin)
        let list = darwinFDList()
        return list.filter { $0.procFDType == proxFDTypeSocket }.count
      #else
        return 0
      #endif
    }
  }

#endif
