// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

/// Adversarial empirical test suite for Milestone 3 Work Item W8 (Consumer Validation Stress & Edge Testing).
///
/// Authored by Challenger 2 to stress-test NWX read monitoring and FleetAgent mutation
/// workflows strictly through public interfaces without `@testable import`.
final class ConsumerValidationChallenger2Tests: XCTestCase {

  // MARK: - 1. NWX Consumer Migration Stress Testing

  // MARK: 1.1 Rapid Event Stream Bursts Under Queue Bounds (reportGap vs fail)

  func testStreamBurstExceedingQueueBoundsReportsStateGapWithoutMemoryLeak() async throws {
    // Under queue bounds of 5 events, burst 50 events rapidly before consumer iteration
    let bounds = StreamBufferBounds(maxEventCount: 5, overflowStrategy: .reportGap)

    var streamEvents: [MockStreamEvent] = []
    for i in 1...50 {
      streamEvents.append(.jsonLine("{\"State\": 6, \"Version\": \"1.80.\(i)\"}"))
    }

    let transport = MockTransport.scriptedStream(streamEvents)
    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let stream = try await client.watchIPNBusEvents(
      options: [.initialState],
      retryPolicy: .none,
      bounds: bounds
    )

    // Allow producer to run burst and encounter queue overflow before consumer starts draining
    try await Task.sleep(for: .milliseconds(50))

    var observedStateGaps = 0
    var observedNotifications = 0

    for try await event in stream {
      switch event {
      case .lifecycle(let lifecycle):
        if case .stateGap(let reason) = lifecycle {
          if reason == "buffer_overflow" {
            observedStateGaps += 1
          }
        }
      case .notification:
        observedNotifications += 1
      }
    }

    XCTAssertGreaterThanOrEqual(
      observedStateGaps, 1,
      "Queue overflow under reportGap must emit .stateGap(reason: \"buffer_overflow\")")
    XCTAssertLessThan(
      observedNotifications, 50,
      "Stale notifications must have been dropped rather than causing unbounded queue buffering")
  }

  func testStreamBurstUnderFailingQueueBoundsThrowsStreamOverflow() async throws {
    // Under fail strategy, exceeding bounds must throw TailscaleClientError.streamOverflow
    let bounds = StreamBufferBounds(maxEventCount: 5, overflowStrategy: .fail)

    var streamEvents: [MockStreamEvent] = []
    for i in 1...20 {
      streamEvents.append(.jsonLine("{\"State\": 6, \"Version\": \"1.80.\(i)\"}"))
    }

    let transport = MockTransport.scriptedStream(streamEvents)
    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let stream = try await client.watchIPNBusEvents(
      options: [.initialState],
      retryPolicy: .none,
      bounds: bounds
    )

    // Allow producer to burst into queue and trigger overflow failure
    try await Task.sleep(for: .milliseconds(50))

    var didCatchStreamOverflow = false
    do {
      for try await _ in stream {
        // Drain until overflow
      }
    } catch let error as TailscaleClientError {
      if case .streamOverflow = error {
        didCatchStreamOverflow = true
      }
    }

    XCTAssertTrue(
      didCatchStreamOverflow,
      "Queue overflow with overflowStrategy == .fail must throw TailscaleClientError.streamOverflow"
    )
  }

  // MARK: 1.2 Synthetic Drops (.stateGap) Asserting Baseline Status Refresh Invocation

  func testSequentialSyntheticDropsTriggerStatusBaselineRefreshes() async throws {
    actor NWXStateTracker {
      var refreshCount = 0
      var refreshedBackendStates: [BackendState?] = []
      var gapsEncountered: [String] = []

      func recordRefresh(state: BackendState?) {
        refreshCount += 1
        refreshedBackendStates.append(state)
      }

      func recordGap(reason: String) {
        gapsEncountered.append(reason)
      }

      var summary: (Int, [BackendState?], [String]) {
        (refreshCount, refreshedBackendStates, gapsEncountered)
      }
    }

    let tracker = NWXStateTracker()

    // Simulate 2 sequential synthetic drops:
    // Drop 1: Malformed unparseable line -> emits .stateGap(reason: "undecodable_line")
    // Drop 2: Network transport drop -> retry reconnect -> emits .stateGap(reason: "reconnected")
    struct SyntheticTransportDrop: Error, Sendable {}

    let scripts: [MockStreamingScript] = [
      MockStreamingScript(
        statusCode: 200,
        headers: [:],
        events: [
          .line(Data("MALFORMED UNPARSEABLE LINE\n".utf8)),
          .jsonLine("{\"State\": 6}"),
          .failure(SyntheticTransportDrop()),
        ]
      ),
      MockStreamingScript(
        statusCode: 200,
        headers: [:],
        events: [
          .jsonLine("{\"State\": 6}"),
          .delay(.seconds(2)),
        ]
      ),
    ]

    actor StatusStateServer {
      var statusCallCount = 0
      func nextStatus() -> TailscaleResponse {
        statusCallCount += 1
        let state = statusCallCount == 1 ? "Running" : "Starting"
        let json = "{\"Version\": \"1.80.0\", \"BackendState\": \"\(state)\"}"
        return TailscaleResponse(statusCode: 200, data: Data(json.utf8))
      }
      var count: Int { statusCallCount }
    }

    let statusServer = StatusStateServer()

    let baseTransport = MockTransport.scriptedResponses(scripts)

    let transport = MockTransport(
      handler: { request, _ in
        if request.path == "/localapi/v0/status" {
          return await statusServer.nextStatus()
        }
        return TailscaleResponse(statusCode: 404, data: Data())
      },
      streaming: { req, cfg in
        try await baseTransport.sendStreaming(req, configuration: cfg)
      }
    )

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    let retryPolicy = StreamRetryPolicy(
      maxAttempts: 2,
      initialDelay: .milliseconds(5),
      maxDelay: .milliseconds(20),
      jitter: 0.0
    )

    let stream = try await client.watchIPNBusEvents(retryPolicy: retryPolicy)

    var notificationCount = 0
    streamLoop: for try await event in stream {
      switch event {
      case .lifecycle(let lifecycle):
        if case .stateGap(let reason) = lifecycle {
          await tracker.recordGap(reason: reason)
          // NWX consumer pattern: whenever .stateGap occurs, re-seed baseline status
          let freshStatus = try await client.status()
          await tracker.recordRefresh(state: freshStatus.backendState)
        }
      case .notification:
        notificationCount += 1
        if notificationCount >= 2 {
          // Received notifications from both stream segments
          break streamLoop
        }
      }
    }

    let (refreshCount, states, gaps) = await tracker.summary
    XCTAssertEqual(
      refreshCount, 2,
      "Must have invoked baseline status refresh exactly twice (once per state gap)"
    )
    XCTAssertTrue(
      gaps.contains("undecodable_line"), "Must have encountered undecodable_line gap")
    XCTAssertTrue(
      gaps.contains("reconnected"), "Must have encountered reconnected gap")
    XCTAssertEqual(states, [.running, .starting])
  }

  // MARK: 1.3 Consumer Task Cancellation During Stream Iteration

  func testConsumerTaskCancellationTerminatesPromptlyWithoutTaskLeaks() async throws {
    // Mock transport that yields one initial line and keeps stream open indefinitely
    let transport = MockTransport(
      handler: { _, _ in TailscaleResponse(statusCode: 200, data: Data()) },
      streaming: { _, _ in
        StreamingResponse(
          statusCode: 200,
          headers: [:],
          body: AsyncThrowingStream { continuation in
            continuation.yield(Data("{\"State\": 6}\n".utf8))
            // Do not finish; stream stays alive awaiting cancel
          }
        )
      }
    )

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    actor ConsumerSync {
      var didReceiveEvent = false
      var didComplete = false
      func markReceived() { didReceiveEvent = true }
      func markCompleted() { didComplete = true }
      var isReady: Bool { didReceiveEvent }
      var isFinished: Bool { didComplete }
    }

    let sync = ConsumerSync()

    let consumerTask = Task<Void, Error> {
      let stream = try await client.watchIPNBusEvents(retryPolicy: .none)
      for try await event in stream {
        if case .notification = event {
          await sync.markReceived()
        }
      }
      await sync.markCompleted()
    }

    // Wait until initial notification is received
    for _ in 1...100 {
      if await sync.isReady { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let ready = await sync.isReady
    XCTAssertTrue(ready, "Consumer must receive initial notification")

    // Now cancel consumer task and measure prompt termination
    let cancelStart = Date()
    consumerTask.cancel()

    // Await task result; should complete promptly with CancellationError or return
    do {
      try await consumerTask.value
    } catch is CancellationError {
      // Expected cancellation
    } catch {
      XCTFail("Unexpected error on cancellation: \(error)")
    }

    let elapsed = Date().timeIntervalSince(cancelStart)
    XCTAssertLessThan(
      elapsed, 0.5,
      "Consumer task cancellation must terminate in under 500ms (elapsed: \(elapsed)s)")
    XCTAssertTrue(consumerTask.isCancelled)
  }

  // MARK: - 2. FleetAgent Configuration Stress Testing

  // MARK: 2.1 ServeConfig Optimistic Concurrency: 3 Consecutive HTTP 412 Conflicts Before Success

  func testServeConfigThreeConsecutiveConflictsWithRetryBackoff() async throws {
    actor FlakyConcurrencyDaemon {
      var writeAttempts = 0
      var currentEtag = "etag-0"
      var configs: [String: String] = [
        "etag-0": "{\"TCP\": {\"80\": {\"TCPForward\": \"127.0.0.1:8080\"}}}",
        "etag-1":
          "{\"TCP\": {\"80\": {\"TCPForward\": \"127.0.0.1:8080\"}, \"81\": {\"TCPForward\": \"127.0.0.1:8081\"}}}",
        "etag-2":
          "{\"TCP\": {\"80\": {\"TCPForward\": \"127.0.0.1:8080\"}, \"82\": {\"TCPForward\": \"127.0.0.1:8082\"}}}",
        "etag-3":
          "{\"TCP\": {\"80\": {\"TCPForward\": \"127.0.0.1:8080\"}, \"83\": {\"TCPForward\": \"127.0.0.1:8083\"}}}",
      ]

      func get() -> (String, String) {
        (currentEtag, configs[currentEtag] ?? "{}")
      }

      func post(ifMatch: String?, body: Data) -> (Int, [String: String], Data) {
        writeAttempts += 1
        if writeAttempts <= 3 {
          // Reject with 412 and advance server state
          currentEtag = "etag-\(writeAttempts)"
          return (412, [:], Data("412 Precondition Failed: ETag mismatch".utf8))
        } else {
          // 4th attempt: Success!
          currentEtag = "etag-final"
          configs["etag-final"] = String(data: body, encoding: .utf8) ?? "{}"
          return (200, ["ETag": "etag-final"], body)
        }
      }

      var attempts: Int { writeAttempts }
    }

    let daemon = FlakyConcurrencyDaemon()

    let transport = MockTransport { request, _ in
      if request.path == "/localapi/v0/serve-config" {
        if request.method == "GET" {
          let (etag, body) = await daemon.get()
          return TailscaleResponse(statusCode: 200, data: Data(body.utf8), headers: ["ETag": etag])
        } else if request.method == "POST" {
          let ifMatch = request.additionalHeaders["If-Match"]
          let (status, headers, body) = await daemon.post(
            ifMatch: ifMatch, body: request.body ?? Data())
          return TailscaleResponse(statusCode: status, data: body, headers: headers)
        }
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let config = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 42111),
      authToken: "test-token",
      transport: transport
    )
    let client = TailscaleClient(configuration: config)

    // FleetAgent optimistic concurrency retry loop with exponential backoff
    var attemptsMade = 0
    var backoffDelays: [Duration] = []
    var currentSnapshot = try await client.serveConfigSnapshot()
    var finalSnapshot: ServeConfigSnapshot?

    let maxRetries = 5
    var currentDelay: Duration = .milliseconds(10)

    for _ in 1...maxRetries {
      attemptsMade += 1
      do {
        let result = try await client.updateServeConfig(currentSnapshot) { cfg in
          cfg.tcp[443] = TCPPortHandler(tcpForward: "127.0.0.1:8443")
        }
        finalSnapshot = result
        break
      } catch TailscaleClientError.preconditionFailed {
        // Concurrency conflict: sleep with backoff, then re-fetch fresh snapshot
        backoffDelays.append(currentDelay)
        try await Task.sleep(for: currentDelay)
        currentDelay *= 2
        currentSnapshot = try await client.serveConfigSnapshot()
      }
    }

    let serverAttempts = await daemon.attempts
    XCTAssertEqual(
      serverAttempts, 4,
      "Must have attempted write exactly 4 times (3 conflicts + 1 successful write)")
    XCTAssertEqual(attemptsMade, 4)
    XCTAssertEqual(backoffDelays.count, 3, "Must have performed 3 backoff intervals")
    XCTAssertEqual(
      backoffDelays,
      [.milliseconds(10), .milliseconds(20), .milliseconds(40)],
      "Backoff delays must follow exponential progression"
    )

    let unwrappedFinal = try XCTUnwrap(finalSnapshot)
    XCTAssertEqual(unwrappedFinal.etag, "etag-final")
    XCTAssertNotNil(unwrappedFinal.config.tcp[443])
    XCTAssertEqual(unwrappedFinal.config.tcp[443]?.tcpForward, "127.0.0.1:8443")
  }

  // MARK: 2.2 Deeply Nested Unmodeled Field & 64-bit Limits Preservation

  func testDeeplyNestedUnmodeledJSONAnd64BitBoundaryPreservation() throws {
    // Raw ServeConfig JSON with:
    // - Deeply nested objects & arrays across root, TCP, Web, and Handler levels
    // - Int64.max (9223372036854775807)
    // - Int64.min (-9223372036854775808)
    // - UInt64.max (18446744073709551615)
    // - UTF-8 multi-byte unicode strings and nulls
    let rawJSON = """
      {
        "TCP": {
          "443": {
            "HTTPS": true,
            "TCPForward": "127.0.0.1:8000",
            "UnmodeledTCPMeta": {
              "level1": {
                "level2": {
                  "level3": ["element1", 9223372036854775807, false, null]
                }
              }
            }
          }
        },
        "Web": {
          "api.corp.ts.net:443": {
            "Handlers": {
              "/v1": {
                "Proxy": "http://127.0.0.1:5000",
                "UnmodeledHandlerLimits": {
                  "minInt64": -9223372036854775808,
                  "nestedList": [{"key": "val1"}, {"key": "val2"}]
                }
              }
            },
            "UnmodeledWebFlags": [true, false, true]
          }
        },
        "RootUnmodeledInt64Max": 9223372036854775807,
        "RootUnmodeledInt64Min": -9223372036854775808,
        "RootUnmodeledUInt64Max": 18446744073709551615,
        "RootUnmodeledDeepTree": {
          "branchA": {
            "branchB": {
              "branchC": {
                "branchD": {
                  "leafString": "deep-value-🚀",
                  "leafNumbers": [0, -1, 42, 18446744073709551615]
                }
              }
            }
          }
        }
      }
      """

    let decoder = JSONDecoder()
    let config = try decoder.decode(ServeConfig.self, from: Data(rawJSON.utf8))

    // 1. Assert 64-bit integer limits and deep structures at root
    XCTAssertEqual(config.unmodeledFields["RootUnmodeledInt64Max"], .integer(Int64.max))
    XCTAssertEqual(config.unmodeledFields["RootUnmodeledInt64Min"], .integer(Int64.min))
    XCTAssertEqual(config.unmodeledFields["RootUnmodeledUInt64Max"], .unsignedInteger(UInt64.max))

    guard case .object(let deepTree) = config.unmodeledFields["RootUnmodeledDeepTree"],
      case .object(let branchB) = deepTree["branchA"],
      case .object(let branchC) = branchB["branchB"],
      case .object(let branchD) = branchC["branchC"],
      case .object(let leaf) = branchD["branchD"]
    else {
      XCTFail("RootUnmodeledDeepTree structure failed to decode recursively")
      return
    }
    XCTAssertEqual(leaf["leafString"], .string("deep-value-🚀"))

    // 2. Assert nested unmodeled structures in TCP
    let tcp443 = try XCTUnwrap(config.tcp[443])
    guard case .object(let tcpMeta) = tcp443.unmodeledFields["UnmodeledTCPMeta"],
      case .object(let l2) = tcpMeta["level1"],
      case .object(let l3) = l2["level2"],
      case .array(let items) = l3["level3"]
    else {
      XCTFail("UnmodeledTCPMeta failed to decode recursively")
      return
    }
    XCTAssertEqual(items.count, 4)
    XCTAssertEqual(items[0], .string("element1"))
    XCTAssertEqual(items[1], .integer(Int64.max))
    XCTAssertEqual(items[2], .bool(false))
    XCTAssertEqual(items[3], .null)

    // 3. Assert nested unmodeled structures in Web & Handler
    let web = try XCTUnwrap(config.web["api.corp.ts.net:443"])
    XCTAssertEqual(
      web.unmodeledFields["UnmodeledWebFlags"], .array([.bool(true), .bool(false), .bool(true)]))
    let handler = try XCTUnwrap(web.handlers["/v1"])
    guard case .object(let hLimits) = handler.unmodeledFields["UnmodeledHandlerLimits"] else {
      XCTFail("UnmodeledHandlerLimits missing")
      return
    }
    XCTAssertEqual(hLimits["minInt64"], .integer(Int64.min))

    // 4. Mutate modeled fields (e.g. add new TCP port, add new Web path)
    var mutated = config
    mutated.tcp[8443] = TCPPortHandler(tcpForward: "127.0.0.1:9443")
    mutated.allowFunnel["api.corp.ts.net:443"] = true

    // 5. Encode -> Redecode
    let encoder = JSONEncoder()
    let encodedData = try encoder.encode(mutated)
    let redecoded = try decoder.decode(ServeConfig.self, from: encodedData)

    // 6. Assert modeled changes succeeded
    XCTAssertEqual(redecoded.tcp[8443]?.tcpForward, "127.0.0.1:9443")
    XCTAssertEqual(redecoded.allowFunnel["api.corp.ts.net:443"], true)

    // 7. Assert complete lossless roundtrip of all deeply nested fields & 64-bit boundaries
    XCTAssertEqual(redecoded.unmodeledFields["RootUnmodeledInt64Max"], .integer(Int64.max))
    XCTAssertEqual(redecoded.unmodeledFields["RootUnmodeledInt64Min"], .integer(Int64.min))
    XCTAssertEqual(
      redecoded.unmodeledFields["RootUnmodeledUInt64Max"], .unsignedInteger(UInt64.max))
    XCTAssertEqual(
      redecoded.unmodeledFields["RootUnmodeledDeepTree"],
      config.unmodeledFields["RootUnmodeledDeepTree"]
    )

    let redecodedTCP = try XCTUnwrap(redecoded.tcp[443])
    XCTAssertEqual(
      redecodedTCP.unmodeledFields["UnmodeledTCPMeta"],
      tcp443.unmodeledFields["UnmodeledTCPMeta"]
    )

    let redecodedWeb = try XCTUnwrap(redecoded.web["api.corp.ts.net:443"])
    XCTAssertEqual(
      redecodedWeb.unmodeledFields["UnmodeledWebFlags"],
      web.unmodeledFields["UnmodeledWebFlags"]
    )
    XCTAssertEqual(
      redecodedWeb.handlers["/v1"]?.unmodeledFields["UnmodeledHandlerLimits"],
      handler.unmodeledFields["UnmodeledHandlerLimits"]
    )
  }

  // MARK: 2.3 MaskedPrefs Untouched Property Isolation Verification

  func testMaskedPrefsUntouchedPropertiesNeverEmitMaskFlags() throws {
    // 1. Default MaskedPrefs must be empty and serialize to empty JSON object
    let emptyPrefs = MaskedPrefs()
    XCTAssertTrue(emptyPrefs.isEmpty)

    let encoder = JSONEncoder()
    let emptyData = try encoder.encode(emptyPrefs)
    let emptyObj = try XCTUnwrap(
      JSONSerialization.jsonObject(with: emptyData) as? [String: Any]
    )
    XCTAssertTrue(
      emptyObj.isEmpty, "Empty MaskedPrefs must encode to empty JSON object with 0 keys")

    // 2. All 17 individual properties must ONLY emit their own value and <Name>Set = true
    let allPropertyNames: [String] = [
      "RouteAll",
      "ExitNodeID",
      "ExitNodeIP",
      "ExitNodeAllowLANAccess",
      "CorpDNS",
      "RunSSH",
      "RunWebClient",
      "WantRunning",
      "ShieldsUp",
      "AdvertiseTags",
      "Hostname",
      "AdvertiseRoutes",
      "NoSNAT",
      "OperatorUser",
      "PostureChecking",
    ]

    for property in allPropertyNames {
      var prefs = MaskedPrefs()
      switch property {
      case "RouteAll": prefs.routeAll = true
      case "ExitNodeID": prefs.exitNodeID = "node-abc"
      case "ExitNodeIP": prefs.exitNodeIP = "100.64.0.5"
      case "ExitNodeAllowLANAccess": prefs.exitNodeAllowLANAccess = false
      case "CorpDNS": prefs.corpDNS = true
      case "RunSSH": prefs.runSSH = false
      case "RunWebClient": prefs.runWebClient = true
      case "WantRunning": prefs.wantRunning = true
      case "ShieldsUp": prefs.shieldsUp = false
      case "AdvertiseTags": prefs.advertiseTags = ["tag:server"]
      case "Hostname": prefs.hostname = "custom-host"
      case "AdvertiseRoutes": prefs.advertiseRoutes = ["10.0.0.0/24"]
      case "NoSNAT": prefs.noSNAT = true
      case "OperatorUser": prefs.operatorUser = "daemon-user"
      case "PostureChecking": prefs.postureChecking = true
      default: XCTFail("Unknown property: \(property)")
      }

      let data = try encoder.encode(prefs)
      let dict = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
      )

      // Exactly 2 keys: Property and PropertySet
      XCTAssertEqual(
        dict.count, 2,
        "Setting only \(property) must produce exactly 2 keys in payload: \(property) and \(property)Set"
      )
      XCTAssertNotNil(dict[property], "\(property) must be present in JSON")
      XCTAssertEqual(
        dict["\(property)Set"] as? Bool, true,
        "\(property)Set must be explicitly true")

      // Verify no other property's <Name>Set is present
      for other in allPropertyNames where other != property {
        XCTAssertNil(
          dict["\(other)Set"],
          "Untouched property \(other)Set must NEVER be emitted when setting \(property)"
        )
        XCTAssertNil(
          dict[other],
          "Untouched property \(other) must NEVER be emitted when setting \(property)"
        )
      }
      XCTAssertNil(dict["AutoUpdate"])
      XCTAssertNil(dict["AutoUpdateSet"])
    }

    // 3. AutoUpdate nested property isolation
    var autoCheckOnly = MaskedPrefs()
    autoCheckOnly.autoUpdateCheck = true
    let checkData = try encoder.encode(autoCheckOnly)
    let checkObj = try XCTUnwrap(
      JSONSerialization.jsonObject(with: checkData) as? [String: Any]
    )

    XCTAssertEqual(checkObj.count, 2)
    let autoUpdateVal = try XCTUnwrap(checkObj["AutoUpdate"] as? [String: Any])
    let autoUpdateMask = try XCTUnwrap(checkObj["AutoUpdateSet"] as? [String: Any])

    XCTAssertEqual(autoUpdateVal["Check"] as? Bool, true)
    XCTAssertEqual(autoUpdateMask["CheckSet"] as? Bool, true)
    XCTAssertNil(autoUpdateVal["Apply"], "Untouched AutoUpdate.Apply must not be present")
    XCTAssertNil(autoUpdateMask["ApplySet"], "Untouched AutoUpdateSet.ApplySet must not be present")

    var autoApplyOnly = MaskedPrefs()
    autoApplyOnly.autoUpdateApply = false
    let applyData = try encoder.encode(autoApplyOnly)
    let applyObj = try XCTUnwrap(
      JSONSerialization.jsonObject(with: applyData) as? [String: Any]
    )

    let applyVal = try XCTUnwrap(applyObj["AutoUpdate"] as? [String: Any])
    let applyMask = try XCTUnwrap(applyObj["AutoUpdateSet"] as? [String: Any])
    XCTAssertEqual(applyVal["Apply"] as? Bool, false)
    XCTAssertEqual(applyMask["ApplySet"] as? Bool, true)
    XCTAssertNil(applyVal["Check"], "Untouched AutoUpdate.Check must not be present")
    XCTAssertNil(applyMask["CheckSet"], "Untouched AutoUpdateSet.CheckSet must not be present")
  }
}
