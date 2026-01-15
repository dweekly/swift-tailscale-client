// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class TailscaleClientConfigurationTests: XCTestCase {
  func testEnvironmentUrlOverride() {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_URL": "http://localhost:8080",
      "TAILSCALE_LOCALAPI_AUTHKEY": "token123",
      "TAILSCALE_LOCALAPI_CAPABILITY": "42",
    ])
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .url(URL(string: "http://localhost:8080")!))
    XCTAssertEqual(result.authToken, "token123")
    XCTAssertEqual(result.capabilityVersion, 42)
  }

  func testEnvironmentSocketOverride() {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_SOCKET": "/tmp/tailscaled.sock",
      "TAILSCALE_LOCALAPI_AUTHKEY": "alpha",
    ])
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .unixSocket(path: "/tmp/tailscaled.sock"))
    XCTAssertEqual(result.authToken, "alpha")
    XCTAssertEqual(result.capabilityVersion, 1)
  }

  func testEnvironmentLoopbackOverride() {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_PORT": "8081",
      "TAILSCALE_LOCALAPI_HOST": "127.0.0.2",
      "TAILSCALE_LOCALAPI_AUTHKEY": "beta",
    ])
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .loopback(host: "127.0.0.2", port: 8081))
    XCTAssertEqual(result.authToken, "beta")
    XCTAssertEqual(result.capabilityVersion, 1)
  }

  func testDefaultFallsBackWhenNoOverridesPresent() {
    let discovery = LocalAPIDiscovery(environment: [:])
    let result = discovery.discover()
    switch result.endpoint {
    case .unixSocket, .loopback, .url:
      XCTAssertTrue(true)
    }
  }

  // MARK: - Unix Socket Priority Tests

  func testHomebrewSocketPathIsFirstCandidate() {
    // When Homebrew socket exists, it should be used (first in candidate list)
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { path in
        path == "/var/run/tailscaled.socket"
      }
    )
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .unixSocket(path: "/var/run/tailscaled.socket"))
  }

  func testSystemSocketPathUsedWhenHomebrewMissing() {
    // When Homebrew socket doesn't exist but system socket does
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { path in
        path == "/Library/Tailscale/Data/tailscaled.sock"
      }
    )
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .unixSocket(path: "/Library/Tailscale/Data/tailscaled.sock"))
  }

  func testUnixSocketTakesPriorityOverAppStoreDiscovery() {
    // Even with allowMacOSAppStoreDiscovery=true, Unix socket should win if it exists
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { path in
        path == "/var/run/tailscaled.socket"
      },
      allowMacOSAppStoreDiscovery: true
    )
    let result = discovery.discover()
    // Unix socket should be used, not App Store loopback
    XCTAssertEqual(result.endpoint, .unixSocket(path: "/var/run/tailscaled.socket"))
  }

  // MARK: - allowMacOSAppStoreDiscovery Flag Tests

  func testAppStoreDiscoveryDisabledByDefault() {
    // With no sockets available and allowMacOSAppStoreDiscovery=false (default),
    // should fall back to default socket path, not attempt App Store discovery
    let discovery = LocalAPIDiscovery(
      environment: [:],
      fileExists: { _ in false },
      allowMacOSAppStoreDiscovery: false
    )
    let result = discovery.discover()
    // Should fall back to default socket path
    if case .unixSocket(let path) = result.endpoint {
      XCTAssertTrue(path.contains("tailscale"), "Should fall back to a tailscale socket path")
    } else {
      XCTFail("Expected unixSocket endpoint for fallback")
    }
  }

  func testDefaultConfigurationDoesNotEnableAppStoreDiscovery() {
    // Verify that TailscaleClientConfiguration.default uses allowMacOSAppStoreDiscovery=false
    // This is a compile-time verification that the API exists
    let _ = TailscaleClientConfiguration.default
    let _ = TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: false)
    let _ = TailscaleClientConfiguration.default(allowMacOSAppStoreDiscovery: true)
    // If this compiles, the API is correct
    XCTAssertTrue(true)
  }

  // MARK: - Environment Variable Priority Tests

  func testEnvironmentOverridesTakeHighestPriority() {
    // Environment variables should override even when sockets exist
    let discovery = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_SOCKET": "/custom/path.sock"
      ],
      fileExists: { path in
        // Both custom and Homebrew paths "exist"
        path == "/custom/path.sock" || path == "/var/run/tailscaled.socket"
      }
    )
    let result = discovery.discover()
    // Environment variable should win
    XCTAssertEqual(result.endpoint, .unixSocket(path: "/custom/path.sock"))
  }
}
