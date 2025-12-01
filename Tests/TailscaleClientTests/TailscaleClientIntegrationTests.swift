// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

#if canImport(Darwin)
  final class TailscaleClientIntegrationTests: XCTestCase {

    // MARK: - Setup

    private var client: TailscaleClient!

    override func setUp() async throws {
      try await super.setUp()
      guard ProcessInfo.processInfo.environment["TAILSCALE_INTEGRATION"] == "1" else {
        throw XCTSkip("Integration tests disabled. Set TAILSCALE_INTEGRATION=1 to enable.")
      }
      client = TailscaleClient()
    }

    // MARK: - Status Endpoint Tests

    func testStatusAgainstLiveDaemon() async throws {
      let status = try await client.status()
      XCTAssertNotNil(
        status.selfNode, "Expected live status response to include self node information")
      XCTAssertNotNil(status.version, "Expected version string")
      XCTAssertFalse(status.version?.isEmpty ?? true, "Expected non-empty version string")
      XCTAssertNotNil(status.backendState, "Expected backend state")
    }

    func testStatusWithPeers() async throws {
      let statusWithPeers = try await client.status(query: StatusQuery(includePeers: true))
      XCTAssertNotNil(statusWithPeers.selfNode)
      // Peers may or may not be present depending on tailnet configuration
    }

    func testStatusWithoutPeers() async throws {
      let statusWithoutPeers = try await client.status(query: StatusQuery(includePeers: false))
      XCTAssertNotNil(statusWithoutPeers.selfNode)
      // When peers=false, the Peer dictionary should be empty or nil
      XCTAssertTrue(
        statusWithoutPeers.peers.isEmpty,
        "Expected no peers when includePeers=false")
    }

    // MARK: - WhoIs Endpoint Tests

    func testWhoIsWithSelfIP() async throws {
      // First get our own IP from status
      let status = try await client.status()
      guard let selfIP = status.tailscaleIPs.first else {
        throw XCTSkip("No Tailscale IPs available")
      }

      let whoIs = try await client.whois(address: selfIP)
      XCTAssertNotNil(whoIs.node, "Expected node info for self IP")
      XCTAssertNotNil(whoIs.userProfile, "Expected user profile for self IP")
    }

    func testWhoIsWithInvalidIP() async throws {
      // This should fail with an error from the API
      do {
        _ = try await client.whois(address: "192.168.1.1")  // Non-Tailscale IP
        // Some versions may return empty response instead of error
      } catch let error as TailscaleClientError {
        // Expected - either 400 or 404 depending on Tailscale version
        if case .unexpectedStatus(let code, _, _) = error {
          XCTAssertTrue(
            code == 400 || code == 404,
            "Expected 400 or 404 for non-Tailscale IP, got \(code)")
        }
      } catch {
        // Other errors are unexpected but we won't fail the test
        XCTFail("Unexpected error type: \(error)")
      }
    }

    // MARK: - Prefs Endpoint Tests

    func testPrefsAgainstLiveDaemon() async throws {
      let prefs = try await client.prefs()
      // Basic validation - controlURL should be set
      XCTAssertNotNil(prefs.controlURL, "Expected controlURL to be present")
      // wantRunning should typically be true if we're connected
      XCTAssertEqual(prefs.wantRunning, true, "Expected wantRunning to be true")
    }

    // MARK: - Ping Endpoint Tests

    func testPingToSelfIP() async throws {
      // Get our own IP
      let status = try await client.status()
      guard let selfIP = status.tailscaleIPs.first else {
        throw XCTSkip("No Tailscale IPs available")
      }

      // Pinging self should return quickly but might error
      let result = try await client.ping(ip: selfIP)
      // Self-ping might return isLocalIP=true or an error
      if let error = result.error, !error.isEmpty {
        XCTAssertTrue(
          result.isLocalIP == true || error.contains("local"),
          "Expected local IP indication for self-ping")
      }
    }

    func testPingWithDifferentTypes() async throws {
      let status = try await client.status()
      guard let selfIP = status.tailscaleIPs.first else {
        throw XCTSkip("No Tailscale IPs available")
      }

      // Test different ping types - they should all complete (even if with errors)
      for pingType in [PingType.disco, .tsmp] {
        let result = try await client.ping(ip: selfIP, type: pingType)
        // Just verify we get a response
        XCTAssertNotNil(result.ip)
      }
    }

    func testPingToPeer() async throws {
      let status = try await client.status()

      // Find an online peer to ping
      guard let onlinePeer = status.peers.values.first(where: { $0.online == true }) else {
        throw XCTSkip("No online peers available for ping test")
      }

      guard let peerIP = onlinePeer.tailscaleIPs.first else {
        throw XCTSkip("Peer has no Tailscale IPs")
      }

      let result = try await client.ping(ip: peerIP)
      if result.isSuccess {
        XCTAssertNotNil(result.latencySeconds, "Expected latency for successful ping")
        XCTAssertNotNil(result.latencyDescription, "Expected latency description")
        // Check if direct or relayed
        if result.isDirect {
          XCTAssertNotNil(result.endpoint, "Expected endpoint for direct ping")
        } else if result.derpRegionID != nil && result.derpRegionID! > 0 {
          XCTAssertNotNil(result.derpRegionCode, "Expected DERP region code for relayed ping")
        }
      }
    }

    // MARK: - Metrics Endpoint Tests

    func testMetricsAgainstLiveDaemon() async throws {
      let metrics = try await client.metrics()
      XCTAssertFalse(metrics.isEmpty, "Expected non-empty metrics response")
      // Metrics should be in Prometheus format
      XCTAssertTrue(
        metrics.contains("tailscale") || metrics.contains("# HELP") || metrics.contains("# TYPE"),
        "Expected Prometheus-format metrics")
    }

    func testMetricsContainsExpectedMetrics() async throws {
      let metrics = try await client.metrics()
      // Common metrics that should be present
      let expectedPatterns = [
        "derp",  // DERP-related metrics
        "magicsock",  // MagicSock metrics
      ]

      var foundCount = 0
      for pattern in expectedPatterns {
        if metrics.lowercased().contains(pattern) {
          foundCount += 1
        }
      }
      // At least some metrics should be present
      XCTAssertGreaterThan(foundCount, 0, "Expected to find some standard Tailscale metrics")
    }

    // MARK: - Transport Layer Tests

    func testTransportHeaderInjection() async throws {
      // Verify the client is using proper headers by checking status works
      // (if headers weren't set correctly, the request would fail)
      let status = try await client.status()
      XCTAssertNotNil(status.selfNode)
    }

    func testMultipleSequentialRequests() async throws {
      // Verify transport handles multiple sequential requests correctly
      for _ in 0..<3 {
        let status = try await client.status()
        XCTAssertNotNil(status.selfNode)
      }
    }

    func testConcurrentRequests() async throws {
      // Verify transport handles concurrent requests
      // Create separate clients to avoid data race issues with Swift 6 concurrency
      let client1 = TailscaleClient()
      let client2 = TailscaleClient()
      let client3 = TailscaleClient()

      async let status1 = client1.status()
      async let status2 = client2.status()
      async let prefs = client3.prefs()

      let results = try await (status1, status2, prefs)
      XCTAssertNotNil(results.0.selfNode)
      XCTAssertNotNil(results.1.selfNode)
      XCTAssertNotNil(results.2.controlURL)
    }

    // MARK: - Error Handling Tests

    func testSocketNotFoundError() async throws {
      // Create a client with a non-existent socket path
      let configuration = TailscaleClientConfiguration(
        endpoint: .unixSocket(path: "/nonexistent/path/tailscaled.sock"),
        authToken: nil,
        capabilityVersion: 1,
        transport: URLSessionTailscaleTransport())
      let badClient = TailscaleClient(configuration: configuration)

      await assertThrowsErrorAsync(try await badClient.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError,
          case .socketNotFound(let path) = transportError
        else {
          XCTFail("Expected socketNotFound error, got \(error)")
          return
        }
        XCTAssertEqual(path, "/nonexistent/path/tailscaled.sock")
      }
    }

    func testConnectionRefusedError() async throws {
      // Create a client pointing to a port that's not listening
      let configuration = TailscaleClientConfiguration(
        endpoint: .loopback(host: "127.0.0.1", port: 59999),  // Unlikely to be in use
        authToken: "fake-token",
        capabilityVersion: 1,
        transport: URLSessionTailscaleTransport())
      let badClient = TailscaleClient(configuration: configuration)

      await assertThrowsErrorAsync(try await badClient.status()) { error in
        guard let clientError = error as? TailscaleClientError,
          case .transport(let transportError) = clientError
        else {
          XCTFail("Expected transport error, got \(error)")
          return
        }
        // Could be connectionRefused or networkFailure depending on OS
        switch transportError {
        case .connectionRefused, .networkFailure:
          break  // Expected
        default:
          XCTFail("Expected connectionRefused or networkFailure, got \(transportError)")
        }
      }
    }

    // MARK: - Configuration Discovery Tests

    func testDefaultConfigurationDiscovery() async throws {
      // The default configuration should auto-discover the LocalAPI
      let defaultClient = TailscaleClient()
      let status = try await defaultClient.status()
      XCTAssertNotNil(status.selfNode, "Default configuration should discover LocalAPI")
    }
  }
#endif
