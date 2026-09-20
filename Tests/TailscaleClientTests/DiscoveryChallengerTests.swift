// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Scriptable mock transport for challenger tests
actor ChallengerMockTransport: TailscaleTransport {
  var callCount = 0
  var observedTokens: [String?] = []
  var observedPorts: [UInt16] = []
  var sendHandler:
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
    observedTokens.append(configuration.authToken)
    if case .loopback(_, let port) = configuration.endpoint {
      observedPorts.append(port)
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
    return StreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.finish()
      }
    )
  }
}

/// Empirical adversarial test suite challenging:
/// 1. Symlink edge cases (dangling, circular, relative traversal, non-numeric, whitespace, permissions)
/// 2. Token resolution edge cases (empty, whitespace-only, corrupt non-UTF8, unreadable permissions, precedence)
/// 3. Candidate priority and graceful fallback (live socket precedence, stopped socket fallback to standalone, App Store isolation)
/// 4. Asynchronous non-blocking behavior, bounded probe times, and cooperative Task cancellation
/// 5. Dynamic re-discovery, single-flight coalescing, thread-safe configuration access, and mutation safety
final class DiscoveryChallengerTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("discovery-challenger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    // Restore permissions in case any test made files unreadable
    if let enumerator = FileManager.default.enumerator(atPath: tempDir.path) {
      for case let element as String in enumerator {
        let fullPath = tempDir.appendingPathComponent(element).path
        chmod(fullPath, 0o755)
      }
    }
    chmod(tempDir.path, 0o755)
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - 1. Symlink Edge Cases

  #if os(macOS)
    func testSymlinkDanglingNonNumericTargetReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "nonexistent_target")

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Dangling non-numeric symlink must be rejected as .notInstalled")
    }

    func testSymlinkOutOfRangeHighPortReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      // 65536 exceeds UInt16.max (65535)
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "65536")

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Port > 65535 must fail UInt16 parsing and yield .notInstalled")
    }

    func testSymlinkNegativePortReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "-1")

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Negative port string must fail UInt16 parsing and yield .notInstalled")
    }

    func testSymlinkZeroPortReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "0")

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Port 0 must be rejected (port > 0 required) and yield .notInstalled")
    }

    func testSymlinkCircularDestinationReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      // Pointing directly back to itself: ipnport -> ipnport
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "ipnport")

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Circular self-referencing symlink must fail numeric parsing and yield .notInstalled")
    }

    func testSymlinkPathTraversalTargetReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "../../etc/hosts")

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Path traversal symlink target must fail numeric parsing and yield .notInstalled")
    }

    func testSymlinkAlphanumericNoiseReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275abc")

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Alphanumeric noise appended to port must fail UInt16 parsing")
    }

    func testSymlinkHexadecimalPortReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "0xc000")

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Hexadecimal port format must fail base-10 UInt16 parsing")
    }

    func testSymlinkValidPortWithMissingTokenReturnsStopped() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      // Neither sameuserproof-49275 nor ipnport.token exists

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .stopped(.loopback(host: "127.0.0.1", port: 49275)),
        "Valid port symlink with missing token indicates daemon stopped/not fully initialized")
    }

    func testRegularFilePortFallbackWithWhitespaceTrimming() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try "  54321 \r\n".write(to: ipnportURL, atomically: true, encoding: .utf8)
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-54321")
      try "valid-token-content\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { port, token in
        port == 54321 && token == "valid-token-content"
      }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.port, 54321)
      XCTAssertEqual(result?.token, "valid-token-content")
    }

    func testRegularFilePortFallbackNonNumericReturnsNotInstalled() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try "invalid-port-string\n".write(to: ipnportURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .notInstalled,
        "Regular file with non-numeric content must yield .notInstalled")
    }
  #endif

  // MARK: - 2. Token Edge Cases

  #if os(macOS)
    func testTokenFileWhitespaceOnlyRejectedAsInvalidCredentials() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "  \t \r\n \n ".write(to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { _, _ in true }

      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .invalidCredentials(.loopback(host: "127.0.0.1", port: 49275)),
        "Whitespace-only token file must be rejected as invalidCredentials")
    }

    func testTokenFileEmptyRejectedAsInvalidCredentials() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try Data().write(to: tokenURL)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { _, _ in true }

      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      XCTAssertEqual(
        inspection, .invalidCredentials(.loopback(host: "127.0.0.1", port: 49275)),
        "Zero-byte token file must be rejected as invalidCredentials")
    }

    func testTokenFileTrailingNewlinesCorrectlyTrimmed() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "\n\r  secret-token-hex-998877 \r\n\n".write(
        to: tokenURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { port, token in
        port == 49275 && token == "secret-token-hex-998877"
      }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.token, "secret-token-hex-998877")
    }

    func testTokenCorruptNonUtf8BytesClassifiedAsInaccessible() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      // Non-UTF8 byte sequence: 0xFF, 0xFE, 0xC0, 0x80
      let corruptBytes = Data([0xFF, 0xFE, 0xC0, 0x80, 0x00, 0x11])
      try corruptBytes.write(to: tokenURL)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { _, _ in true }

      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      guard case .inaccessible(let path, _) = inspection else {
        XCTFail("Corrupt non-UTF8 token must be classified as .inaccessible, got \(inspection)")
        return
      }
      XCTAssertEqual(path, tokenURL.path)
    }

    func testTokenUnreadablePermissionsClassifiedAsInaccessible() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "super-secret-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)
      // Make file unreadable (0000)
      chmod(tokenURL.path, 0o000)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { _, _ in true }

      let inspection = info.inspectStandalone(sharedDirectory: tempDir)
      guard case .inaccessible(let path, let reason) = inspection else {
        XCTFail(
          "Unreadable token file must be classified as .inaccessible, got \(inspection)")
        return
      }
      XCTAssertEqual(path, tokenURL.path)
      XCTAssertTrue(
        reason.contains("Permission denied") || reason.contains("0640"),
        "Diagnostic reason must cite permission denial: \(reason)")
    }

    func testTokenPrecedencePrimarySameuserproofWinsOverFallback() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let primaryURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "primary-token-111\n".write(to: primaryURL, atomically: true, encoding: .utf8)
      let fallbackURL = tempDir.appendingPathComponent("ipnport.token")
      try "fallback-token-222\n".write(to: fallbackURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { port, token in
        port == 49275 && token == "primary-token-111"
      }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNotNil(result)
      XCTAssertEqual(
        result?.token, "primary-token-111",
        "Primary sameuserproof-<port> must take precedence over fallback ipnport.token")
    }

    func testTokenFallbackUsedWhenPrimaryDoesNotExist() throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let fallbackURL = tempDir.appendingPathComponent("ipnport.token")
      try "fallback-token-only\n".write(to: fallbackURL, atomically: true, encoding: .utf8)

      var info = MacClientInfo()
      info.standaloneDirectoryOverride = tempDir
      info.probeOverride = { port, token in
        port == 49275 && token == "fallback-token-only"
      }

      let result = info.locateStandalone(sharedDirectory: tempDir)
      XCTAssertNotNil(result)
      XCTAssertEqual(result?.token, "fallback-token-only")
    }
  #endif

  // MARK: - 3. Candidate Priority & Fallback Precedence

  #if os(macOS)
    func testLiveUnixSocketPrecedenceOverLiveStandalone() async throws {
      // Set up a mock live Unix socket and a mock live standalone .pkg
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "standalone-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      let socketPath = "/var/run/tailscaled.socket"
      let discovery = LocalAPIDiscovery(
        environment: [:],
        fileExists: { path in
          path == socketPath
        },
        allowMacOSAppStoreDiscovery: false,
        socketProber: { path in
          (isAlive: path == socketPath, error: nil)
        },
        standaloneDirectoryOverride: tempDir,
        probeOverride: { _, _ in true }
      )

      let result = try await discovery.discoverAsync()
      XCTAssertEqual(
        result.endpoint, TailscaleEndpoint.unixSocket(path: socketPath),
        "Documented precedence: live Unix socket takes precedence over standalone loopback")
    }

    func testStoppedUnixSocketFallsBackToLiveStandalone() async throws {
      // Set up a mock STOPPED Unix socket and a LIVE standalone .pkg
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "standalone-live-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      let socketPath = "/var/run/tailscaled.socket"
      let discovery = LocalAPIDiscovery(
        environment: [:],
        fileExists: { path in
          path == socketPath
        },
        allowMacOSAppStoreDiscovery: false,
        socketProber: { path in
          // Refuses connection (e.g. ECONNREFUSED)
          (isAlive: false, error: .stopped(candidate: .unixSocket(path: path)))
        },
        standaloneDirectoryOverride: tempDir,
        probeOverride: { port, token in
          port == 49275 && token == "standalone-live-token"
        }
      )

      let result = try await discovery.discoverAsync()
      XCTAssertEqual(
        result.endpoint, TailscaleEndpoint.loopback(host: "127.0.0.1", port: 49275),
        "Stopped Unix socket must gracefully fall back to live standalone .pkg")
      XCTAssertEqual(result.authToken, "standalone-live-token")
    }

    func testInaccessibleUnixSocketFallsBackToLiveStandalone() async throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "standalone-live-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      let socketPath = "/var/run/tailscaled.socket"
      let discovery = LocalAPIDiscovery(
        environment: [:],
        fileExists: { path in
          path == socketPath
        },
        allowMacOSAppStoreDiscovery: false,
        socketProber: { path in
          // Permission denied
          (isAlive: false, error: .inaccessible(path: path, reason: "Permission denied (EACCES)"))
        },
        standaloneDirectoryOverride: tempDir,
        probeOverride: { port, token in
          port == 49275 && token == "standalone-live-token"
        }
      )

      let result = try await discovery.discoverAsync()
      XCTAssertEqual(
        result.endpoint, TailscaleEndpoint.loopback(host: "127.0.0.1", port: 49275),
        "Inaccessible Unix socket must fall back to live standalone .pkg")
    }

    func testStoppedUnixSocketAndStoppedStandaloneYieldsStoppedError() async throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "standalone-token\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      let socketPath = "/var/run/tailscaled.socket"
      let discovery = LocalAPIDiscovery(
        environment: [:],
        fileExists: { path in
          path == socketPath
        },
        allowMacOSAppStoreDiscovery: false,
        socketProber: { path in
          (isAlive: false, error: .stopped(candidate: .unixSocket(path: path)))
        },
        standaloneDirectoryOverride: tempDir,
        probeOverride: { _, _ in false }  // standalone also stopped!
      )

      do {
        _ = try await discovery.discoverAsync()
        XCTFail("Expected stopped error when both candidates refuse connections")
      } catch let error as LocalAPIDiscoveryError {
        guard case .stopped = error else {
          XCTFail("Expected .stopped error, got \(error)")
          return
        }
      }
    }

    func testAppStoreIsolationWhenOptInDisabled() async throws {
      // When standalone and Unix sockets fail, App Store GUI is NOT queried
      let discovery = LocalAPIDiscovery(
        environment: [:],
        fileExists: { _ in false },
        allowMacOSAppStoreDiscovery: false,  // Opt-in disabled!
        standaloneDirectoryOverride: tempDir  // empty directory
      )

      do {
        _ = try await discovery.discoverAsync()
        XCTFail("Expected .notInstalled")
      } catch let error as LocalAPIDiscoveryError {
        XCTAssertEqual(
          error, .notInstalled,
          "With allowMacOSAppStoreDiscovery false, App Store scan must be skipped completely")
      }
    }
  #endif

  // MARK: - 4. Non-Blocking & Asynchronous Behavior

  @MainActor
  func testDiscoverAsyncDoesNotDeadlockOnMainActor() async throws {
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "54321",
        "TAILSCALE_LOCALAPI_AUTHKEY": "async-test-token",
      ]
    )
    let result = try await discovery.discoverAsync()
    XCTAssertEqual(result.endpoint, TailscaleEndpoint.loopback(host: "127.0.0.1", port: 54321))
    XCTAssertEqual(result.authToken, "async-test-token")
  }

  func testProbeUnixSocketBoundedPollTimeout() throws {
    // Probing a non-existent or unconnectable Unix socket does not block indefinitely
    let nonExistentSocket = tempDir.appendingPathComponent("dead.sock").path
    // Create an empty file that is not a listening socket
    try "not a socket".write(toFile: nonExistentSocket, atomically: true, encoding: .utf8)

    let start = Date()
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { path in path == nonExistentSocket },
      allowMacOSAppStoreDiscovery: false,
      standaloneDirectoryOverride: tempDir
    )

    let exp = expectation(description: "discoverAsync completes within deadline")
    Task {
      do {
        _ = try await discovery.discoverAsync()
        XCTFail("Expected failure on dead socket")
      } catch {
        exp.fulfill()
      }
    }

    wait(for: [exp], timeout: 3.0)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(
      elapsed, 2.5,
      "Probe of unconnectable socket must be strictly bounded (< 2.5s), took \(elapsed)s")
  }

  func testCancellationStopsDetachedProbes() async throws {
    actor CallCounter {
      var count = 0
      func increment() { count += 1 }
    }
    let counter = CallCounter()

    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in
        // Sleep on each check to simulate slow filesystem/probe
        Thread.sleep(forTimeInterval: 0.05)
        Task { await counter.increment() }
        return false
      },
      allowMacOSAppStoreDiscovery: false,
      standaloneDirectoryOverride: tempDir
    )

    let task = Task {
      try await discovery.discoverAsync()
    }
    // Cancel immediately before all candidates are scanned
    task.cancel()

    var caughtCancellation = false
    var caughtError: Error?
    do {
      _ = try await task.value
    } catch is CancellationError {
      caughtCancellation = true
    } catch {
      caughtError = error
    }

    let calls = await counter.count

    // REMEDIATION VERIFICATION:
    // Cooperative cancellation links caller task cancellation to the detached task.
    // Therefore, cancelling the caller's Task:
    // 1. Cancels the detached task early (candidate checks < 5).
    // 2. Throws CancellationError cleanly.
    XCTAssertTrue(
      caughtCancellation,
      "discoverAsync() detached task receives cancellation and throws CancellationError")
    XCTAssertLessThan(
      calls, 5,
      "Candidate filesystem probes stop early upon caller cancellation")
    XCTAssertNil(
      caughtError,
      "Expected CancellationError rather than a non-cancellation error")
  }

  func testDiscoverAsyncTaskCancellationStress() async throws {
    // Stress test: launching multiple tasks that are cancelled concurrently
    let slowDiscovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in
        Thread.sleep(forTimeInterval: 0.02)
        return false
      },
      allowMacOSAppStoreDiscovery: false,
      standaloneDirectoryOverride: tempDir
    )

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask {
          let task = Task {
            try await slowDiscovery.discoverAsync()
          }
          task.cancel()
          do {
            _ = try await task.value
          } catch {
            XCTAssertTrue(task.isCancelled)
          }
        }
      }
    }
  }

  // MARK: - 5. Dynamic Recovery, Single-Flight Coalescing & Mutation Safety

  func testPinnedEndpointNeverAttemptsRediscovery() async throws {
    let transport = ChallengerMockTransport()
    await transport.setHandler { _, _ in
      throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:50001")
    }

    let pinnedConfig = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 50001),
      authToken: "pinned-secret",
      transport: transport,
      endpointSource: .pinned(.loopback(host: "127.0.0.1", port: 50001))
    )
    let client = TailscaleClient(configuration: pinnedConfig)

    do {
      _ = try await client.status()
      XCTFail("Pinned client must throw transport error")
    } catch let error as TailscaleClientError {
      guard case .transport(.connectionRefused) = error else {
        XCTFail("Expected .transport(.connectionRefused), got \(error)")
        return
      }
    }

    let calls = await transport.callCount
    XCTAssertEqual(calls, 1, "Pinned endpoint must make exactly 1 attempt and never retry")
    XCTAssertEqual(client.configuration.authToken, "pinned-secret")
  }

  func testSingleFlightCoalescingUnderHighConcurrency() async throws {
    let transport = ChallengerMockTransport()

    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "50002",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-refreshed-50002",
      ]
    )

    await transport.setHandler { _, config in
      if config.authToken == "stale-initial-token" {
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:50000")
      }
      return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
    }

    let initialResult = LocalAPIDiscovery.Result(
      endpoint: .loopback(host: "127.0.0.1", port: 50000),
      authToken: "stale-initial-token",
      capabilityVersion: 144
    )
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: initialResult,
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // Launch 25 concurrent requests hitting connectionRefused simultaneously
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<25 {
        group.addTask {
          let status = try await client.status()
          XCTAssertEqual(status.backendState, .running)
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(client.configuration.authToken, "token-refreshed-50002")
    XCTAssertEqual(
      client.configuration.endpoint, TailscaleEndpoint.loopback(host: "127.0.0.1", port: 50002))
  }

  func testMutationSafetyReplaysConnectStageRefusal() async throws {
    // Mutating POST rejected before connection established (ECONNREFUSED) is safe to replay
    let transport = ChallengerMockTransport()

    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "50004",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-50004",
      ]
    )

    await transport.setHandler { req, config in
      if config.authToken == "token-stale" {
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:50003")
      }
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }

    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 50003),
        authToken: "token-stale",
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // Mutating call (setDNS)
    try await client.setDNS(name: "example.com", value: "1.2.3.4")

    let tokens = await transport.observedTokens
    XCTAssertEqual(
      tokens, ["token-stale", "token-50004"],
      "Mutating request rejected with connectionRefused must safely replay once after rediscovery")
  }

  func testMutationSafetyNeverReplaysAmbiguousMidStreamFailure() async throws {
    // Mutating POST failing mid-stream (e.g. malformed response or broken pipe) must NOT replay
    let transport = ChallengerMockTransport()

    await transport.setHandler { _, _ in
      throw TailscaleTransportError.malformedResponse(detail: "Broken pipe while sending POST body")
    }

    let discovery = LocalAPIDiscovery(
      environment: ["TAILSCALE_LOCALAPI_AUTHKEY": "token-new"]
    )
    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 50005),
        authToken: "token-old",
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    do {
      try await client.setDNS(name: "example.org", value: "9.9.9.9")
      XCTFail("Expected transport error on mid-stream failure")
    } catch let error as TailscaleClientError {
      guard case .transport(.malformedResponse) = error else {
        XCTFail("Expected .transport(.malformedResponse), got \(error)")
        return
      }
    }

    let callCount = await transport.callCount
    XCTAssertEqual(
      callCount, 1,
      "Ambiguous mid-stream transport error on mutating request must NEVER be replayed")
  }

  func testThreadSafeConfigurationReadsDuringConcurrentRediscovery() async throws {
    let transport = ChallengerMockTransport()

    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_PORT": "50006",
        "TAILSCALE_LOCALAPI_AUTHKEY": "token-updated",
      ]
    )

    await transport.setHandler { _, config in
      if config.authToken == "token-initial" {
        // Slow recovery simulation
        try? await Task.sleep(nanoseconds: 10_000_000)
        throw TailscaleTransportError.connectionRefused(endpoint: "127.0.0.1:50005")
      }
      return TailscaleResponse(statusCode: 200, data: Data("{\"BackendState\":\"Running\"}".utf8))
    }

    let config = TailscaleClientConfiguration(
      discovery: discovery,
      result: .init(
        endpoint: .loopback(host: "127.0.0.1", port: 50005),
        authToken: "token-initial",
        capabilityVersion: 144
      ),
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // Simultaneously read client.configuration from 20 background tasks while client.status() recovers
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = try await client.status()
      }
      for _ in 0..<20 {
        group.addTask {
          for _ in 0..<100 {
            let current = client.configuration
            XCTAssertTrue(
              current.authToken == "token-initial" || current.authToken == "token-updated")
          }
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(client.configuration.authToken, "token-updated")
  }
}
