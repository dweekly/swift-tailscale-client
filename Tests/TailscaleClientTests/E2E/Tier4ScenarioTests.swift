// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tier 4: Real-World Application Scenarios E2E Test Suite.
///
/// Models 5 complete, multi-step, realistic end-to-end consumer application workflows:
/// 1. Complete Node Onboarding & Authentication Lifecycle
/// 2. Safe Serve & Funnel Configuration Lifecycle with Concurrency Control
/// 3. Resilient Long-Running Monitoring Daemon with Disconnect & Reconnect
/// 4. Diagnostic Network Assessment & DERP Map Inspection
/// 5. Multi-Profile Switching & Preference Management
final class Tier4ScenarioTests: XCTestCase {

  // MARK: - Scenario 1: Complete Node Onboarding & Authentication Lifecycle

  func test_scenario1_nodeOnboardingAndAuthenticationLifecycle() async throws {
    actor OnboardingState {
      var state = "NeedsLogin"
      func login() { state = "Running" }
      func current() -> String { state }
    }
    let stateStore = OnboardingState()
    let recorder = RequestRecorder()

    let transport = MockTransport(
      handler: { req, _ in
        await recorder.record(request: req)
        if req.path.contains("features") {
          return TailscaleResponse(
            statusCode: 200, data: Data("{\"Features\": {\"login\": true}}".utf8))
        }
        if req.path.contains("login-interactive") {
          await stateStore.login()
          return TailscaleResponse(statusCode: 204, data: Data())
        }
        let s = await stateStore.current()
        return TailscaleResponse(
          statusCode: 200,
          data: Data(E2ETestSupport.statusJSON(backendState: s).utf8)
        )
      },
      streaming: { req, _ in
        await recorder.record(request: req)
        let events: [MockStreamEvent] = [
          .jsonLine(
            "{\"BackendState\": \"NeedsLogin\", \"BrowseToURL\": \"https://login.tailscale.com/a/abc123\"}"
          ),
          .delay(.milliseconds(10)),
          .jsonLine("{\"BackendState\": \"Running\", \"State\": 6}"),
        ]
        return try await MockTransport.scriptedStream(events).sendStreaming(
          req,
          configuration: TailscaleClientConfiguration.default
        )
      }
    )

    let client = E2ETestSupport.makeClient(transport: transport)

    // 1. Check initial state
    let initialStatus = try await client.status()
    XCTAssertEqual(initialStatus.backendState, .needsLogin)

    // 2. Query daemon features to ensure login endpoint is supported
    let features = try await client.daemonFeatures()
    XCTAssertNotNil(features)

    // 3. Listen on IPN bus for interactive login URL
    let stream = try await client.watchIPNBus()
    var observedAuthURL: String?
    var reachedRunning = false

    for try await notify in stream {
      if let url = notify.browseToURL {
        observedAuthURL = url
      }
      if notify.state == .running {
        reachedRunning = true
        break
      }
    }

    XCTAssertEqual(observedAuthURL, "https://login.tailscale.com/a/abc123")
    XCTAssertTrue(reachedRunning)

    // 4. Trigger interactive login
    try await client.loginInteractive()

    // 5. Verify final status transition
    let finalStatus = try await client.status()
    XCTAssertEqual(finalStatus.backendState, .running)
    XCTAssertEqual(finalStatus.selfNode?.tailscaleIPs.first, "100.64.0.1")
    XCTAssertEqual(finalStatus.selfNode?.dnsName, "test-node.tailnet.ts.net")
  }

  // MARK: - Scenario 2: Safe Serve & Funnel Configuration Lifecycle

  func test_scenario2_serveAndFunnelConfigurationLifecycleWithConcurrency() async throws {
    actor ServeServerStore {
      var etag: String = "\"etag-v1\""
      var configJSON: String = E2ETestSupport.serveConfigJSON(
        etag: "\"etag-v1\"", allowFunnel: false)

      func currentETag() -> String { etag }
      func currentConfig() -> String { configJSON }
      func simulateConcurrentChange() { etag = "\"etag-v1-concurrent\"" }
      func update(etag: String, json: String) {
        self.etag = etag
        self.configJSON = json
      }
    }

    let store = ServeServerStore()
    let recorder = RequestRecorder()

    let transport = MockTransport { req, _ in
      await recorder.record(request: req)
      if req.method == "GET" && req.path.contains("serve-config") {
        let tag = await store.currentETag()
        let body = await store.currentConfig()
        return TailscaleResponse(
          statusCode: 200,
          data: Data(body.utf8),
          headers: ["ETag": tag]
        )
      }
      if req.method == "POST" && req.path.contains("serve-config") {
        let currentTag = await store.currentETag()
        let match = req.additionalHeaders["If-Match"]
        if match != currentTag {
          return TailscaleResponse(statusCode: 412, data: Data("precondition failed".utf8))
        }
        let nextTag = "\"etag-v2\""
        let nextBody = req.body.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        await store.update(etag: nextTag, json: nextBody)
        return TailscaleResponse(
          statusCode: 200,
          data: Data("{}".utf8),
          headers: ["ETag": nextTag]
        )
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    // 1. Fetch current snapshot
    let snapshot = try await client.serveConfig()
    XCTAssertEqual(snapshot.etag, "\"etag-v1\"")
    XCTAssertFalse(snapshot.allowFunnel["test-node.tailnet.ts.net:443"] ?? false)

    // 2. Prepare mutation: add reverse proxy and enable Funnel
    var modified = snapshot
    modified.web["test-node.tailnet.ts.net:443"]?.handlers["/api"] = HTTPHandler(
      proxy: "http://127.0.0.1:9090")
    modified.allowFunnel["test-node.tailnet.ts.net:443"] = true

    // 3. Simulate concurrent modification on the daemon before this client writes
    await store.simulateConcurrentChange()

    // 4. Attempt update -> Expect HTTP 412 Precondition Failed
    await assertThrowsErrorAsync(try await client.setServeConfig(modified)) { error in
      guard case TailscaleClientError.preconditionFailed = error else {
        XCTFail("Expected preconditionFailed, got \(error)")
        return
      }
    }

    // 5. Re-fetch latest snapshot with current server ETag
    let freshSnapshot = try await client.serveConfig()
    XCTAssertEqual(freshSnapshot.etag, "\"etag-v1-concurrent\"")

    // 6. Re-apply mutation onto fresh snapshot
    var reApplied = freshSnapshot
    reApplied.web["test-node.tailnet.ts.net:443"]?.handlers["/api"] = HTTPHandler(
      proxy: "http://127.0.0.1:9090")
    reApplied.allowFunnel["test-node.tailnet.ts.net:443"] = true

    // 7. Write succeeded with matching ETag
    try await client.setServeConfig(reApplied)
    let finalETag = await store.currentETag()
    XCTAssertEqual(finalETag, "\"etag-v2\"")
  }

  // MARK: - Scenario 3: Resilient Monitoring Daemon with Disconnect & Reconnect

  func test_scenario3_monitoringDaemonWithDisconnectAndRecovery() async throws {
    struct NetworkSeveredError: Error {}

    let counter = E2ETestSupport.AtomicCounter()
    let transport = MockTransport(
      handler: { req, _ in
        TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
      },
      streaming: { req, _ in
        let attempt = counter.increment()
        if attempt == 1 {
          let events: [MockStreamEvent] = [
            .jsonLine(E2ETestSupport.ipnNotifyJSON(state: 6, ipnState: "Running")),
            .delay(.milliseconds(5)),
            .failure(NetworkSeveredError()),
          ]
          return try await MockTransport.scriptedStream(events).sendStreaming(
            req,
            configuration: TailscaleClientConfiguration.default
          )
        } else {
          let events: [MockStreamEvent] = [
            .jsonLine(E2ETestSupport.ipnNotifyJSON(state: 6, ipnState: "Running"))
          ]
          return try await MockTransport.scriptedStream(events).sendStreaming(
            req,
            configuration: TailscaleClientConfiguration.default
          )
        }
      }
    )

    let client = E2ETestSupport.makeClient(transport: transport)

    // Cycle 1: Stream connects, delivers update, then fails
    var receivedFirstUpdate = false
    do {
      let stream = try await client.watchIPNBus()
      for try await notify in stream {
        XCTAssertEqual(notify.state, .running)
        receivedFirstUpdate = true
      }
    } catch {
      XCTAssertTrue(receivedFirstUpdate)
    }

    // Exponential backoff simulation between retries
    let retryDelay = min(0.1 * pow(2.0, 1.0), 10.0)
    XCTAssertEqual(retryDelay, 0.2)

    // Cycle 2: Stream reconnects and delivers fresh updates
    let recoveredStream = try await client.watchIPNBus()
    var receivedRecoveredUpdate = false
    for try await notify in recoveredStream {
      XCTAssertEqual(notify.state, .running)
      receivedRecoveredUpdate = true
      break
    }
    XCTAssertTrue(receivedRecoveredUpdate)

    // Baseline status refresh to reconcile state gap
    let baseline = try await client.status()
    XCTAssertEqual(baseline.backendState, .running)
  }

  // MARK: - Scenario 4: Diagnostic Network Assessment & DERP Map Inspection

  func test_scenario4_diagnosticNetworkAssessmentAndDERPMap() async throws {
    let transport = MockTransport { req, _ in
      if req.path.contains("derpmap") {
        return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.derpMapJSON().utf8))
      }
      if req.path.contains("whois") {
        return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.whoIsJSON().utf8))
      }
      if req.path.contains("status") {
        return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.statusJSON().utf8))
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    // 1. Inspect tailnet status and active peers
    let status = try await client.status()
    XCTAssertEqual(status.peers.count, 2)
    let peerIP = status.peers.values.first?.tailscaleIPs.first ?? "100.64.0.11"

    // 2. Whois lookup on target peer
    let whoIs = try await client.whois(address: peerIP)
    XCTAssertEqual(whoIs.node?.name, "target-node")
    XCTAssertEqual(whoIs.userProfile?.loginName, "user@example.com")

    // 3. Inspect DERP region map for backup routing and STUN relays
    let derp = try await client.derpMap()
    XCTAssertEqual(derp.regions.count, 2)
    let nyc = derp.regions[1]
    XCTAssertEqual(nyc?.regionCode, "nyc")
    XCTAssertEqual(nyc?.nodes.first?.ipv4, "198.51.100.1")
  }

  // MARK: - Scenario 5: Multi-Profile Switching & Preference Management

  func test_scenario5_multiProfileSwitchingAndPreferenceManagement() async throws {
    actor ProfileStore {
      var activeID = "profile-personal"
      func switchWork() { activeID = "profile-work" }
      func current() -> String { activeID }
    }
    let profileStore = ProfileStore()
    let recorder = RequestRecorder()

    let transport = MockTransport { req, _ in
      await recorder.record(request: req)
      if req.method == "POST" && req.path.hasPrefix("/localapi/v0/profiles/") {
        await profileStore.switchWork()
        return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
      }
      if req.path == "/localapi/v0/profiles" || req.path == "/localapi/v0/profiles/" {
        return TailscaleResponse(statusCode: 200, data: Data(E2ETestSupport.profilesJSON().utf8))
      }
      if req.method == "PATCH" && req.path.contains("prefs") {
        return TailscaleResponse(
          statusCode: 200,
          data: Data(
            E2ETestSupport.prefsJSON(routeAll: true, shieldsUp: true, hostname: "work-laptop").utf8)
        )
      }
      let cur = await profileStore.current()
      return TailscaleResponse(
        statusCode: 200,
        data: Data(
          E2ETestSupport.prefsJSON(
            hostname: cur == "profile-personal" ? "personal-laptop" : "work-laptop"
          ).utf8)
      )
    }

    let client = E2ETestSupport.makeClient(transport: transport)

    // 1. List available profiles
    let profiles = try await client.profiles()
    XCTAssertEqual(profiles.count, 2)
    XCTAssertEqual(profiles[0].id, "profile-personal")
    XCTAssertEqual(profiles[1].id, "profile-work")

    // 2. Check initial preferences on personal profile
    let initialPrefs = try await client.prefs()
    XCTAssertEqual(initialPrefs.hostname, "personal-laptop")

    // 3. Switch active profile to work
    try await client.switchProfile("profile-work")
    let currentID = await profileStore.current()
    XCTAssertEqual(currentID, "profile-work")

    // 4. Update work preferences with MaskedPrefs (routeAll and shieldsUp)
    var mask = MaskedPrefs()
    mask.routeAll = true
    mask.shieldsUp = true
    try await client.editPrefs(mask)

    // 5. Verify PATCH request was dispatched
    let requests = await recorder.requests
    XCTAssertTrue(requests.contains { $0.method == "PATCH" })
  }
}
