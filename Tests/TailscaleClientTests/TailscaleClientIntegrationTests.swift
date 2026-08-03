// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

#if canImport(Darwin) || os(Linux)
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

    // MARK: - Optional Features Tests

    func testDaemonFeaturesAgainstLiveDaemon() async throws {
      do {
        let features = try await client.daemonFeatures()
        // Feature names vary by build; the map existing at all is the contract.
        XCTAssertFalse(
          features.features.isEmpty, "Expected at least one optional feature to be reported")
      } catch let error as TailscaleClientError {
        guard case .endpointUnavailable = error else { throw error }
        throw XCTSkip("Daemon predates debug-optional-features; skipping")
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

    // MARK: - Network Diagnostics Tests

    func testDERPMapAgainstLiveDaemon() async throws {
      let map = try await client.derpMap()
      XCTAssertFalse(map.regions.isEmpty, "Expected at least one DERP region")

      // Every region should be internally consistent.
      for (id, region) in map.regions {
        XCTAssertEqual(id, region.regionID, "Region key should match RegionID")
        XCTAssertFalse(region.nodes.isEmpty, "Region \(id) should have nodes")
        for node in region.nodes {
          XCTAssertFalse(node.hostName.isEmpty, "Node in region \(id) should have a hostname")
          XCTAssertEqual(node.regionID, id)
        }
      }
    }

    func testSuggestExitNodeAgainstLiveDaemon() async throws {
      do {
        let suggestion = try await client.suggestExitNode()
        // Some daemon builds report "no candidates" as an empty 200 rather
        // than an HTTP error (seen on headscale tailnets with no exit nodes).
        guard let id = suggestion.id, !id.isEmpty else {
          throw XCTSkip("Daemon returned an empty suggestion (no exit nodes); skipping")
        }
      } catch let error as TailscaleClientError {
        switch error {
        case .endpointUnavailable:
          throw XCTSkip("Daemon built without exit-node support; skipping")
        case .unexpectedStatus:
          // Expected on tailnets with no exit nodes: the daemon reports the
          // absence of candidates as an HTTP error, not an empty suggestion.
          throw XCTSkip("No exit node candidates on this tailnet: \(error.description)")
        default:
          throw error
        }
      }
    }

    func testUserMetricsAgainstLiveDaemon() async throws {
      do {
        let metrics = try await client.userMetrics()
        XCTAssertFalse(metrics.isEmpty, "Expected non-empty usermetrics response")
        XCTAssertTrue(
          metrics.contains("tailscaled_"),
          "Expected tailscaled_-prefixed user metrics")
      } catch let error as TailscaleClientError {
        guard case .endpointUnavailable = error else { throw error }
        throw XCTSkip("Daemon predates usermetrics; skipping")
      }
    }

    func testNetcheckAgainstLiveDERPMap() async throws {
      let report = try await client.netcheck(options: Netcheck.Options(timeout: .seconds(5)))
      guard report.udpWorking else {
        // CI sandboxes may block outbound UDP entirely; that's a valid
        // report, not a client bug.
        throw XCTSkip("No STUN responses (UDP blocked or empty DERP map); skipping")
      }
      XCTAssertFalse(report.regionLatencySeconds.isEmpty)
      XCTAssertNotNil(report.preferredDERPRegionID, "UDP works, so some region should be preferred")
      if report.ipv4Working {
        XCTAssertNotNil(report.globalV4, "IPv4 STUN worked, so a mapped address should be known")
      }
      for (region, latency) in report.regionLatencySeconds {
        XCTAssertGreaterThan(latency, 0, "Region \(region) latency should be positive")
        XCTAssertLessThan(latency, 5.5, "Region \(region) latency should respect the timeout")
      }
    }

    // MARK: - Profiles (read-only)

    func testProfilesAgainstLiveDaemon() async throws {
      let profiles = try await client.profiles()
      XCTAssertFalse(profiles.isEmpty, "A logged-in daemon should have at least one profile")
      let current = try await client.currentProfile()
      XCTAssertTrue(
        profiles.contains { $0.id == current.id },
        "Current profile should appear in the list")
    }

    // MARK: - Write API Tests (hermetic daemons ONLY)

    /// Write tests mutate daemon state, so they carry their own gate on top
    /// of TAILSCALE_INTEGRATION: only the hermetic headscale environment
    /// sets TAILSCALE_INTEGRATION_WRITE=1. Never enable it against a real
    /// tailnet.
    private func requireWriteTesting() throws {
      guard ProcessInfo.processInfo.environment["TAILSCALE_INTEGRATION_WRITE"] == "1" else {
        throw XCTSkip("Write tests need TAILSCALE_INTEGRATION_WRITE=1 (hermetic daemons only)")
      }
    }

    func testEditPrefsShieldsUpRoundTrip() async throws {
      try requireWriteTesting()
      let original = try await client.prefs()
      let flipped = !(original.shieldsUp ?? false)

      var change = MaskedPrefs()
      change.shieldsUp = flipped
      let updated = try await client.editPrefs(change)
      XCTAssertEqual(updated.shieldsUp, flipped, "editPrefs should apply the masked field")

      var revert = MaskedPrefs()
      revert.shieldsUp = !flipped
      let restored = try await client.editPrefs(revert)
      XCTAssertEqual(restored.shieldsUp, !flipped, "editPrefs should restore the original value")
    }

    func testCheckPrefsAcceptsCurrentPrefs() async throws {
      try requireWriteTesting()
      let current = try await client.prefs()
      // The daemon's own current prefs must validate.
      try await client.checkPrefs(current)
    }

    // MARK: - Peer/User Lookup Tests

    func testPeerAndUserProfileLookupAgainstLiveDaemon() async throws {
      // The numeric IDs come from whois; status carries only stable IDs.
      let status = try await client.status()
      guard let selfIP = status.tailscaleIPs.first else {
        throw XCTSkip("No Tailscale IPs available")
      }
      let whoIs = try await client.whois(address: selfIP)
      guard let node = whoIs.node else {
        throw XCTSkip("whois returned no node for self")
      }

      let fetched = try await client.peer(byID: node.id)
      XCTAssertEqual(fetched.id, node.id)
      XCTAssertEqual(fetched.stableID, node.stableID)

      if let userID = node.user {
        do {
          let profile = try await client.userProfile(byID: userID)
          XCTAssertEqual(profile.id, userID)
          XCTAssertFalse(profile.loginName?.isEmpty ?? true, "Expected a login name")
        } catch let error as TailscaleClientError {
          // user-profile is a 2026 addition; older daemons 404 the unknown
          // path, which is indistinguishable from "user not found". A 404
          // for our own (known-valid) user ID means the daemon predates it.
          guard case .unexpectedStatus(404, _, _) = error else { throw error }
          throw XCTSkip("Daemon predates the user-profile endpoint; skipping")
        }
      }
    }

    func testPeerByIDNotFoundAgainstLiveDaemon() async throws {
      // Small tailnets (headscale!) really do have a node with ID 1, so the
      // bogus ID must be far outside any plausible allocation.
      await assertThrowsErrorAsync(try await client.peer(byID: 999_999_999_999)) { error in
        guard let clientError = error as? TailscaleClientError,
          case .unexpectedStatus(let code, _, _) = clientError
        else {
          XCTFail("Expected unexpectedStatus, got \(error)")
          return
        }
        XCTAssertTrue(code == 404 || code == 400, "Expected not-found for bogus ID, got \(code)")
      }
    }

    // MARK: - DNS Diagnostics Tests

    func testDNSOSConfigAgainstLiveDaemon() async throws {
      do {
        let config = try await client.dnsOSConfig()
        // MagicDNS installs 100.100.100.100; a daemon with DNS disabled may
        // report empty arrays, which is still a valid response.
        print("dns-osconfig: \(config.nameservers) search=\(config.searchDomains.count)")
      } catch let error as TailscaleClientError {
        switch error {
        case .endpointUnavailable:
          throw XCTSkip("Daemon built without DNS support; skipping")
        case .unexpectedStatus(500, _, _):
          // Userspace-networking daemons manage no OS DNS and answer 500.
          throw XCTSkip("Daemon has no OS DNS configuration (userspace mode); skipping")
        default:
          throw error
        }
      }
    }

    func testDNSQueryAgainstLiveDaemon() async throws {
      let status = try await client.status()
      guard let selfNode = status.selfNode, !selfNode.dnsName.isEmpty else {
        throw XCTSkip("No self DNS name available")
      }
      do {
        let response = try await client.dnsQuery(name: selfNode.dnsName)
        XCTAssertGreaterThan(
          response.bytes.count, 12, "Expected a DNS message beyond the 12-byte header")
      } catch let error as TailscaleClientError {
        switch error {
        case .endpointUnavailable:
          throw XCTSkip("Daemon built without DNS support; skipping")
        case .unexpectedStatus(let code, _, _) where code == 403:
          throw XCTSkip("LocalAPI connection lacks write permission for dns-query; skipping")
        default:
          throw error
        }
      }
    }

    func testDNSConfigAgainstLiveDaemon() async throws {
      do {
        let config = try await client.dnsConfig()
        print("dns-config: proxied=\(config.proxied) domains=\(config.domains.count)")
      } catch let error as TailscaleClientError {
        switch error {
        case .endpointUnavailable:
          // The typed unavailability is the asserted contract on daemons
          // older than 1.98 (exercised by the previous-stable lane).
          throw XCTSkip("Daemon predates dns-config (Tailscale 1.98+); skipping")
        case .unexpectedStatus(503, _, _):
          throw XCTSkip("No netmap available yet; skipping")
        default:
          throw error
        }
      }
    }

    func testCheckIPForwardingAgainstLiveDaemon() async throws {
      do {
        let check = try await client.checkIPForwarding()
        // Either outcome is valid; the shape is the contract.
        print("check-ip-forwarding ready=\(check.isReady) warning=\(check.warning ?? "none")")
      } catch let error as TailscaleClientError {
        guard case .endpointUnavailable = error else { throw error }
        throw XCTSkip("Daemon built without route advertising; skipping")
      }
    }

    // MARK: - Experimental Namespace Tests

    func testGoroutinesAgainstLiveDaemon() async throws {
      do {
        let dump = try await client.experimental.goroutines()
        XCTAssertTrue(dump.contains("goroutine"), "Expected a Go stack dump")
      } catch let error as TailscaleClientError {
        switch error {
        case .endpointUnavailable:
          throw XCTSkip("Daemon built without debug support; skipping")
        case .unexpectedStatus(let code, _, _) where code == 403:
          throw XCTSkip("LocalAPI connection lacks write permission for goroutines; skipping")
        default:
          throw error
        }
      }
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

    // MARK: - Interface Discovery Tests

    func testInterfaceDiscovery() async throws {
      #if !canImport(Darwin)
        throw XCTSkip("Interface discovery is Darwin-only (userspace tailscaled has no TUN)")
      #endif
      let status = try await client.status()

      // Should have at least one Tailscale IP
      guard !status.tailscaleIPs.isEmpty else {
        throw XCTSkip("No Tailscale IPs available")
      }

      // Interface discovery should find the TUN interface
      let interfaceName = status.interfaceName
      XCTAssertNotNil(interfaceName, "Expected to discover Tailscale interface")

      // The interface should be a utun device on macOS
      if let name = interfaceName {
        XCTAssertTrue(
          name.hasPrefix("utun"),
          "Expected utun interface, got \(name)")
        print("Tailscale interface discovered: \(name)")
      }
    }

    func testInterfaceInfo() async throws {
      #if !canImport(Darwin)
        throw XCTSkip("Interface discovery is Darwin-only (userspace tailscaled has no TUN)")
      #endif
      let status = try await client.status()

      guard !status.tailscaleIPs.isEmpty else {
        throw XCTSkip("No Tailscale IPs available")
      }

      // Full interface info should be available
      let info = status.interfaceInfo
      XCTAssertNotNil(info, "Expected to get interface info")

      if let info = info {
        // TUN interfaces should be point-to-point
        XCTAssertTrue(info.isPointToPoint, "Expected TUN to be point-to-point")
        XCTAssertTrue(info.isUp, "Expected interface to be up")
        XCTAssertTrue(info.isRunning, "Expected interface to be running")
        XCTAssertFalse(info.isLoopback, "TUN should not be loopback")
        print(
          "Interface \(info.name): up=\(info.isUp), running=\(info.isRunning), p2p=\(info.isPointToPoint)"
        )
      }
    }

    func testNetworkInterfaceDiscoveryDirectly() async throws {
      #if !canImport(Darwin)
        throw XCTSkip("Interface enumeration is Darwin-only; Linux returns empty results")
      #endif
      // Test the discovery utility directly
      let allInterfaces = NetworkInterfaceDiscovery.allInterfaces()
      XCTAssertFalse(allInterfaces.isEmpty, "Expected at least one network interface")

      // Should have loopback
      let hasLoopback = allInterfaces.contains { $0.isLoopback }
      XCTAssertTrue(hasLoopback, "Expected loopback interface")

      // Print all interfaces for debugging
      for iface in allInterfaces {
        print(
          "Interface: \(iface.name) - \(iface.address) (IPv6: \(iface.isIPv6), up: \(iface.isUp))")
      }
    }
  }
#endif
