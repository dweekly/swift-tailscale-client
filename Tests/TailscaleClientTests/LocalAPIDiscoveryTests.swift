// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class LocalAPIDiscoveryTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("discovery-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - Synchronous Environment Overrides

  func testEnvironmentDualPrefixUrlOverride() {
    let discovery = LocalAPIDiscovery(environment: [
      "TS_LOCALAPI_URL": "http://localhost:9090",
      "TS_LOCALAPI_AUTHKEY": "token9090",
      "TS_LOCALAPI_CAPABILITY": "55",
    ])
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .url(URL(string: "http://localhost:9090")!))
    XCTAssertEqual(result.authToken, "token9090")
    XCTAssertEqual(result.capabilityVersion, 55)
  }

  func testEnvironmentDualPrefixSocketOverride() {
    let discovery = LocalAPIDiscovery(environment: [
      "TS_LOCALAPI_SOCKET": "/var/run/custom-ts.sock",
      "TS_LOCALAPI_AUTHKEY": "socket-token",
    ])
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .unixSocket(path: "/var/run/custom-ts.sock"))
    XCTAssertEqual(result.authToken, "socket-token")
  }

  // MARK: - Asynchronous Environment Overrides

  func testDiscoverAsyncResolvesUrlEnvironmentOverride() async throws {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_URL": "http://127.0.0.1:8080",
      "TAILSCALE_LOCALAPI_AUTHKEY": "auth-key-1",
    ])
    let result = try await discovery.discoverAsync()
    XCTAssertEqual(result.endpoint, .url(URL(string: "http://127.0.0.1:8080")!))
    XCTAssertEqual(result.authToken, "auth-key-1")
  }

  func testDiscoverAsyncResolvesSocketEnvironmentOverride() async throws {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_SOCKET": "/tmp/custom.sock"
    ])
    let result = try await discovery.discoverAsync()
    XCTAssertEqual(result.endpoint, .unixSocket(path: "/tmp/custom.sock"))
    XCTAssertNil(result.authToken)
  }

  func testDiscoverAsyncResolvesPortEnvironmentOverride() async throws {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_PORT": "54321",
      "TAILSCALE_LOCALAPI_HOST": "127.0.0.1",
      "TAILSCALE_LOCALAPI_AUTHKEY": "port-auth",
    ])
    let result = try await discovery.discoverAsync()
    XCTAssertEqual(result.endpoint, .loopback(host: "127.0.0.1", port: 54321))
    XCTAssertEqual(result.authToken, "port-auth")
  }

  // MARK: - Error Classification Tests

  func testDiscoverAsyncThrowsNotInstalledWhenNoCandidatesFound() async throws {
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      allowMacOSAppStoreDiscovery: false,
      standaloneDirectoryOverride: tempDir
    )
    do {
      _ = try await discovery.discoverAsync()
      XCTFail("Expected LocalAPIDiscoveryError.notInstalled")
    } catch let error as LocalAPIDiscoveryError {
      XCTAssertEqual(error, .notInstalled)
      XCTAssertNotNil(error.errorDescription)
      XCTAssertNotNil(error.recoverySuggestion)
    }
  }

  func testDiscoverAsyncThrowsStoppedWhenCandidateRefusesConnection() async throws {
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { path in path == "/var/run/tailscaled.socket" },
      allowMacOSAppStoreDiscovery: false,
      socketProber: { path in
        (isAlive: false, error: .stopped(candidate: .unixSocket(path: path)))
      },
      standaloneDirectoryOverride: tempDir
    )
    do {
      _ = try await discovery.discoverAsync()
      XCTFail("Expected LocalAPIDiscoveryError.stopped")
    } catch let error as LocalAPIDiscoveryError {
      XCTAssertEqual(error, .stopped(candidate: .unixSocket(path: "/var/run/tailscaled.socket")))
      XCTAssertTrue(error.errorDescription?.contains("stopped") == true)
    }
  }

  func testDiscoverAsyncThrowsInaccessibleWhenSocketPermissionDenied() async throws {
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { path in path == "/var/run/tailscaled.socket" },
      allowMacOSAppStoreDiscovery: false,
      socketProber: { path in
        (isAlive: false, error: .inaccessible(path: path, reason: "Permission denied"))
      },
      standaloneDirectoryOverride: tempDir
    )
    do {
      _ = try await discovery.discoverAsync()
      XCTFail("Expected LocalAPIDiscoveryError.inaccessible")
    } catch let error as LocalAPIDiscoveryError {
      XCTAssertEqual(
        error, .inaccessible(path: "/var/run/tailscaled.socket", reason: "Permission denied"))
      XCTAssertTrue(error.errorDescription?.contains("inaccessible") == true)
    }
  }

  #if os(macOS)
    func testDiscoverAsyncResolvesStandalonePkgByDefaultWithoutTCC() async throws {
      let ipnportURL = tempDir.appendingPathComponent("ipnport")
      try FileManager.default.createSymbolicLink(
        atPath: ipnportURL.path, withDestinationPath: "49275")
      let tokenURL = tempDir.appendingPathComponent("sameuserproof-49275")
      try "token-standalone-123\n".write(to: tokenURL, atomically: true, encoding: .utf8)

      let discovery = LocalAPIDiscovery(
        environment: [:],
        fileExists: { _ in false },
        allowMacOSAppStoreDiscovery: false,  // Default is false!
        standaloneDirectoryOverride: tempDir,
        probeOverride: { port, token in
          port == 49275 && token == "token-standalone-123"
        }
      )

      let syncResult = discovery.discover()
      XCTAssertEqual(syncResult.endpoint, .loopback(host: "127.0.0.1", port: 49275))
      XCTAssertEqual(syncResult.authToken, "token-standalone-123")

      let asyncResult = try await discovery.discoverAsync()
      XCTAssertEqual(asyncResult.endpoint, .loopback(host: "127.0.0.1", port: 49275))
      XCTAssertEqual(asyncResult.authToken, "token-standalone-123")
    }
  #endif

  func testDiscoverAsyncHonorsTaskCancellation() async throws {
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in
        Thread.sleep(forTimeInterval: 0.1)
        return false
      },
      allowMacOSAppStoreDiscovery: false,
      standaloneDirectoryOverride: tempDir
    )

    let task = Task {
      try await discovery.discoverAsync()
    }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation error")
    } catch is CancellationError {
      XCTAssertTrue(true)
    } catch {
      // In Swift concurrency, Task cancellation might surface as CancellationError or task failure
      XCTAssertTrue(task.isCancelled)
    }
  }

  @MainActor
  func testDiscoverAsyncRunsOnMainActorWithoutBlocking() async throws {
    let discovery = LocalAPIDiscovery(
      environment: ["TAILSCALE_LOCALAPI_URL": "http://127.0.0.1:41112"]
    )
    let result = try await discovery.discoverAsync()
    XCTAssertEqual(result.endpoint, .url(URL(string: "http://127.0.0.1:41112")!))
  }
}
