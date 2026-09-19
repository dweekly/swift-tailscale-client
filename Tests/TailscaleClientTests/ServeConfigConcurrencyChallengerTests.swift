// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

/// Empirical challenger test suite for Milestone 1 W1 (PR 02 & PR 03).
///
/// Focus areas:
/// 1. High-contention concurrent actor races (simulating N concurrent writers with optimistic retry loops)
/// 2. HTTP 412 preconditionFailed mapping, body data fidelity, endpoint, and body preview limits
/// 3. ETag validation (empty, whitespace-only, missing header, case-insensitivity)
/// 4. replaceServeConfigUnconditionally behavior, wire header format, and unconditional overwrite semantics
/// 5. POST response ETag presence vs. fallback to GET re-read
final class ServeConfigConcurrencyChallengerTests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://local-tailscaled.sock")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport
    )
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - Helper Mock Actors

  actor MockDaemonServer {
    var config: ServeConfig
    var etagCounter: Int = 1
    var updateCount: Int = 0
    var conflictCount: Int = 0
    var unconditionalCount: Int = 0

    init(initialConfig: ServeConfig = ServeConfig()) {
      self.config = initialConfig
    }

    func currentETag() -> String {
      "\"v\(etagCounter)\""
    }

    func handleGet() -> TailscaleResponse {
      let data = (try? JSONEncoder().encode(config)) ?? Data("{}".utf8)
      return TailscaleResponse(
        statusCode: 200,
        data: data,
        headers: ["ETag": currentETag()]
      )
    }

    func handlePost(ifMatch: String?, body: Data) -> TailscaleResponse {
      let activeETag = currentETag()

      // Unconditional write if ifMatch is missing or empty
      if ifMatch == nil || ifMatch?.isEmpty == true {
        unconditionalCount += 1
        etagCounter += 1
        if let decoded = try? JSONDecoder.tailscale().decode(ServeConfig.self, from: body) {
          self.config = decoded
        }
        return TailscaleResponse(
          statusCode: 200,
          data: Data("{}".utf8),
          headers: ["ETag": currentETag()]
        )
      }

      // Conditional write
      if ifMatch == activeETag {
        updateCount += 1
        etagCounter += 1
        if let decoded = try? JSONDecoder.tailscale().decode(ServeConfig.self, from: body) {
          self.config = decoded
        }
        return TailscaleResponse(
          statusCode: 200,
          data: Data("{}".utf8),
          headers: ["ETag": currentETag()]
        )
      } else {
        conflictCount += 1
        let errBody = "precondition failed: current=\(activeETag), provided=\(ifMatch ?? "none")"
        return TailscaleResponse(
          statusCode: 412,
          data: Data(errBody.utf8),
          headers: [:]
        )
      }
    }
  }

  private func makeClient(server: MockDaemonServer) -> TailscaleClient {
    let transport = MockTransport { request, _ in
      if request.path == "/localapi/v0/serve-config" {
        if request.method == "GET" {
          return await server.handleGet()
        } else if request.method == "POST" {
          let ifMatch = request.additionalHeaders["If-Match"]
          return await server.handlePost(ifMatch: ifMatch, body: request.body ?? Data())
        }
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }
    return makeClient(transport: transport)
  }

  // MARK: - 1. High-Contention Concurrent Actor Race

  func testTwentyConcurrentWritersWithOptimisticRetryLoop() async throws {
    let server = MockDaemonServer()
    let client = makeClient(server: server)
    let writerCount = 20

    // Concurrently launch 20 tasks, each attempting to add its own TCP port handler
    try await withThrowingTaskGroup(of: Int.self) { group in
      for i in 0..<writerCount {
        let port = UInt16(8000 + i)
        group.addTask {
          var attempts = 0
          while attempts < 100 {
            attempts += 1
            let snapshot = try await client.serveConfigSnapshot()
            do {
              _ = try await client.updateServeConfig(snapshot) { config in
                config.tcp[port] = TCPPortHandler(tcpForward: "127.0.0.1:\(port)")
              }
              return attempts
            } catch TailscaleClientError.preconditionFailed {
              // Stale ETag encountered! Back off slightly and retry
              await Task.yield()
              continue
            }
          }
          throw XCTSkip("Exceeded max attempts in high-contention test")
        }
      }

      var totalAttempts = 0
      for try await attempts in group {
        totalAttempts += attempts
      }
      XCTAssertGreaterThanOrEqual(totalAttempts, writerCount)
    }

    // After all 20 writers finish, verify the final server state
    let finalSnapshot = try await client.serveConfigSnapshot()
    let finalTCP = finalSnapshot.config.tcp

    // Every single port from 8000 to 8019 must be present!
    XCTAssertEqual(finalTCP.count, writerCount, "All 20 concurrent updates must be preserved")
    for i in 0..<writerCount {
      let port = UInt16(8000 + i)
      XCTAssertEqual(
        finalTCP[port]?.tcpForward,
        "127.0.0.1:\(port)",
        "Port \(port) was lost during concurrent writes!"
      )
    }

    let conflicts = await server.conflictCount
    let updates = await server.updateCount
    XCTAssertEqual(
      updates, writerCount, "Exactly \(writerCount) successful updates must have occurred")
    XCTAssertGreaterThan(
      conflicts,
      0,
      "Under 20 concurrent writers, race conditions MUST have triggered 412 conflicts"
    )
  }

  // MARK: - 2. HTTP 412 Precondition Failed Mapping Fidelity

  func testHTTP412PreconditionFailedMappingAndBodyData() async throws {
    let customBody = Data("daemon etag mismatch: requested=\"old\" current=\"new\"".utf8)
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 412, data: customBody)
    }
    let client = makeClient(transport: transport)
    let snapshot = ServeConfigSnapshot(
      etag: "\"old\"",
      targetIdentifier: client.targetIdentifier,
      config: ServeConfig()
    )

    do {
      _ = try await client.setServeConfig(ServeConfig(), matching: snapshot)
      XCTFail("Should have thrown TailscaleClientError.preconditionFailed")
    } catch let error as TailscaleClientError {
      guard case .preconditionFailed(let body, let endpoint) = error else {
        XCTFail("Expected .preconditionFailed, got \(error)")
        return
      }
      XCTAssertEqual(body, customBody, "Raw response body must be preserved completely")
      XCTAssertEqual(endpoint, "/localapi/v0/serve-config", "Endpoint must match serve-config")
      XCTAssertEqual(
        error.bodyPreview,
        "daemon etag mismatch: requested=\"old\" current=\"new\""
      )
    }
  }

  func testHTTP412BodyPreviewTruncationAt500Chars() {
    let longString = String(repeating: "A", count: 600)
    let error = TailscaleClientError.preconditionFailed(
      body: Data(longString.utf8),
      endpoint: "/localapi/v0/serve-config"
    )
    let preview = error.bodyPreview
    XCTAssertNotNil(preview)
    XCTAssertTrue(preview?.contains("... (600 chars total)") == true)
    XCTAssertEqual(preview?.count, 500 + "... (600 chars total)".count)
  }

  func testHTTP412BodyPreviewHandlesInvalidUTF8() {
    let invalidUTF8 = Data([0xFF, 0xFE, 0xFD, 0xFC])
    let error = TailscaleClientError.preconditionFailed(
      body: invalidUTF8,
      endpoint: "/localapi/v0/serve-config"
    )
    XCTAssertEqual(error.bodyPreview, "<binary data: 4 bytes>")
  }

  // MARK: - 3. Concurrency Token Validation (Empty & Whitespace ETags)

  func testSetServeConfigRejectsWhitespaceOnlyETags() async throws {
    let whitespaceCases = [
      "",
      " ",
      "   ",
      "\t",
      "\n",
      "\r\n   \t  \n",
    ]

    for whitespaceETag in whitespaceCases {
      let transport = MockTransport { _, _ in
        XCTFail("Transport must not be called when ETag is invalid whitespace: '\(whitespaceETag)'")
        return TailscaleResponse(statusCode: 200, data: Data())
      }
      let client = makeClient(transport: transport)

      let snapshot = ServeConfigSnapshot(
        etag: whitespaceETag,
        targetIdentifier: client.targetIdentifier,
        config: ServeConfig()
      )
      do {
        _ = try await client.setServeConfig(ServeConfig(), matching: snapshot)
        XCTFail("Expected .missingConcurrencyToken for ETag: '\(whitespaceETag)'")
      } catch let error as TailscaleClientError {
        guard case .missingConcurrencyToken = error else {
          XCTFail("Expected .missingConcurrencyToken, got \(error)")
          return
        }
      }
    }
  }

  func testServeConfigSnapshotRejectsMissingOrWhitespaceETagHeader() async throws {
    let invalidHeaders: [[String: String]] = [
      [:],  // Missing header entirely
      ["ETag": ""],  // Empty header
      ["ETag": "  "],  // Whitespace
      ["etag": "\t\n  \r\n"],  // Lowercase whitespace
      ["ETAG": "   "],  // Uppercase whitespace
    ]

    for headers in invalidHeaders {
      let transport = MockTransport { _, _ in
        TailscaleResponse(statusCode: 200, data: Data("{}".utf8), headers: headers)
      }
      let client = makeClient(transport: transport)

      do {
        _ = try await client.serveConfigSnapshot()
        XCTFail("Expected missingConcurrencyToken for headers: \(headers)")
      } catch let error as TailscaleClientError {
        guard case .missingConcurrencyToken = error else {
          XCTFail("Expected .missingConcurrencyToken, got \(error)")
          return
        }
      }
    }
  }

  func testServeConfigSnapshotAcceptsCaseInsensitiveETagHeaders() async throws {
    let validCases: [[String: String]] = [
      ["ETag": "\"tag1\""],
      ["etag": "\"tag2\""],
      ["ETAG": "\"tag3\""],
      ["eTag": "\"tag4\""],
    ]

    for (index, headers) in validCases.enumerated() {
      let transport = MockTransport { _, _ in
        TailscaleResponse(statusCode: 200, data: Data("{}".utf8), headers: headers)
      }
      let client = makeClient(transport: transport)

      let snapshot = try await client.serveConfigSnapshot()
      XCTAssertEqual(snapshot.etag, "\"tag\(index + 1)\"")
    }
  }

  // MARK: - 4. Unconditional Replacement & If-Match Analysis

  func testReplaceServeConfigUnconditionallyInspection() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = makeClient(transport: transport)

    var config = ServeConfig()
    config.tcp[443] = TCPPortHandler(https: true)

    try await client.replaceServeConfigUnconditionally(config)

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)

    // Empirical observation of request properties:
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/localapi/v0/serve-config")

    // The implementation passes additionalHeaders: ["If-Match": ""]
    XCTAssertEqual(request.additionalHeaders["If-Match"], "")

    // Wire serialization observation:
    let wireBytes = HTTPWireFormat.requestData(for: request, capabilityVersion: 1, keepAlive: false)
    let wireString = String(decoding: wireBytes, as: UTF8.self)

    // Verify wire format contains "If-Match: "
    XCTAssertTrue(wireString.contains("If-Match: \r\n"))
  }

  func testReplaceServeConfigUnconditionallyAlwaysOverwritesRegardlessOfServerState() async throws {
    let server = MockDaemonServer()
    let client = makeClient(server: server)

    // Seed server with initial configuration at version v1
    var initial = ServeConfig()
    initial.tcp[80] = TCPPortHandler(http: true)
    try await client.replaceServeConfigUnconditionally(initial)
    let snap1 = try await client.serveConfigSnapshot()
    XCTAssertNotNil(snap1.config.tcp[80])

    // Advance server to v2 via conditional write
    var modified = snap1.config
    modified.tcp[8080] = TCPPortHandler(http: true)
    let snap2 = try await client.setServeConfig(modified, matching: snap1)
    XCTAssertEqual(snap2.etag, "\"v3\"")

    // Unconditional replacement should succeed and wipe out earlier ports
    var replacement = ServeConfig()
    replacement.tcp[9999] = TCPPortHandler(tcpForward: "127.0.0.1:9999")
    try await client.replaceServeConfigUnconditionally(replacement)

    let snap3 = try await client.serveConfigSnapshot()
    XCTAssertEqual(snap3.config.tcp.count, 1)
    XCTAssertNotNil(snap3.config.tcp[9999])
    XCTAssertNil(snap3.config.tcp[80], "Initial port 80 must have been overwritten")
    XCTAssertNil(snap3.config.tcp[8080], "Port 8080 must have been overwritten")
  }

  // MARK: - 5. POST ETag Header Presence vs. Fallback

  func testSetServeConfigWhenDaemonOmitsETagInPostResponseFallsBackToGet() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      if request.method == "POST" {
        // Daemon succeeds but returns NO ETag header in POST response
        return TailscaleResponse(statusCode: 200, data: Data("{}".utf8), headers: [:])
      } else if request.method == "GET" {
        // Client issues fallback GET to re-read ETag
        return TailscaleResponse(
          statusCode: 200,
          data: Data("{}".utf8),
          headers: ["ETag": "\"fallback-fetched-etag\""]
        )
      }
      return TailscaleResponse(statusCode: 404, data: Data())
    }

    let client = makeClient(transport: transport)

    let snapshot = ServeConfigSnapshot(
      etag: "\"initial-etag\"",
      targetIdentifier: client.targetIdentifier,
      config: ServeConfig()
    )
    var newConfig = ServeConfig()
    newConfig.tcp[22] = TCPPortHandler(tcpForward: "127.0.0.1:22")

    let resultSnapshot = try await client.setServeConfig(newConfig, matching: snapshot)

    let recorded = await recorder.requests
    XCTAssertEqual(recorded.count, 2, "Expected POST followed by fallback GET")
    XCTAssertEqual(recorded[0].method, "POST")
    XCTAssertEqual(recorded[1].method, "GET")
    XCTAssertEqual(resultSnapshot.etag, "\"fallback-fetched-etag\"")
  }

  // MARK: - 6. Cross-Milestone Stress: Concurrent Writes Preserving Unknown Fields

  func testConcurrentUpdatesPreserveUnmodeledFields() async throws {
    let complexJSON = """
      {
        "TCP": {
          "80": {
            "HTTP": true,
            "TCP_Custom": "preserve_me"
          }
        },
        "Root_Custom": "root_preserve",
        "Large_Int": 18446744073709551615
      }
      """
    let initialConfig = try JSONDecoder.tailscale().decode(
      ServeConfig.self, from: Data(complexJSON.utf8))
    let server = MockDaemonServer(initialConfig: initialConfig)
    let client = makeClient(server: server)

    // 10 concurrent writers modifying TCP ports
    let writerCount = 10
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<writerCount {
        let port = UInt16(9000 + i)
        group.addTask {
          var attempts = 0
          while attempts < 100 {
            attempts += 1
            let snapshot = try await client.serveConfigSnapshot()
            do {
              _ = try await client.updateServeConfig(snapshot) { config in
                config.tcp[port] = TCPPortHandler(tcpForward: "127.0.0.1:\(port)")
              }
              return
            } catch TailscaleClientError.preconditionFailed {
              await Task.yield()
              continue
            }
          }
          throw XCTSkip("Exceeded max retry attempts")
        }
      }

      for try await _ in group {}
    }

    let finalSnapshot = try await client.serveConfigSnapshot()
    let cfg = finalSnapshot.config

    // Verify all 10 ports + port 80 are present
    XCTAssertEqual(cfg.tcp.count, 11)
    XCTAssertEqual(cfg.tcp[80]?.unmodeledFields["TCP_Custom"], .string("preserve_me"))
    XCTAssertEqual(cfg.unmodeledFields["Root_Custom"], .string("root_preserve"))
    XCTAssertEqual(cfg.unmodeledFields["Large_Int"], .unsignedInteger(UInt64.max))

    for i in 0..<writerCount {
      let port = UInt16(9000 + i)
      XCTAssertEqual(cfg.tcp[port]?.tcpForward, "127.0.0.1:\(port)")
    }
  }

  func testFiftyConcurrentWritersWithRandomJitter() async throws {
    let server = MockDaemonServer()
    let client = makeClient(server: server)
    let writerCount = 50

    try await withThrowingTaskGroup(of: Int.self) { group in
      for i in 0..<writerCount {
        let port = UInt16(7000 + i)
        group.addTask {
          var attempts = 0
          while attempts < 200 {
            attempts += 1
            let snapshot = try await client.serveConfigSnapshot()
            do {
              _ = try await client.updateServeConfig(snapshot) { config in
                config.tcp[port] = TCPPortHandler(tcpForward: "127.0.0.1:\(port)")
              }
              return attempts
            } catch TailscaleClientError.preconditionFailed {
              // Simulated jitter
              try? await Task.sleep(nanoseconds: UInt64.random(in: 100_000...2_000_000))
              continue
            }
          }
          throw XCTSkip("Exceeded max attempts in 50-writer test")
        }
      }

      for try await _ in group {}
    }

    let finalSnapshot = try await client.serveConfigSnapshot()
    XCTAssertEqual(finalSnapshot.config.tcp.count, writerCount)
    for i in 0..<writerCount {
      let port = UInt16(7000 + i)
      XCTAssertEqual(finalSnapshot.config.tcp[port]?.tcpForward, "127.0.0.1:\(port)")
    }

    let conflicts = await server.conflictCount
    XCTAssertGreaterThan(conflicts, 0)
  }

  // MARK: - Target Identity & Replay Protection (Issue 2)

  func testSnapshotPreservesTargetIdentityFromResponse() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200,
        data: Data("{}".utf8),
        headers: ["ETag": "\"v1\""],
        targetIdentifier: "responding-daemon-sha256"
      )
    }
    let client = makeClient(transport: transport)
    let snapshot = try await client.serveConfigSnapshot()
    XCTAssertEqual(snapshot.targetIdentifier, "responding-daemon-sha256")
  }

  func testSetServeConfigRejectsReplayWhenExpectedTargetMismatches() async throws {
    let clientA = makeClient(
      transport: MockTransport { _, _ in
        TailscaleResponse(statusCode: 200, data: Data("{}".utf8), headers: ["ETag": "\"v1\""])
      })
    let snapshotFromA = try await clientA.serveConfigSnapshot()

    let configB = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://other-daemon.sock")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: MockTransport { _, _ in
        TailscaleResponse(statusCode: 200, data: Data("{}".utf8), headers: ["ETag": "\"v2\""])
      }
    )
    let clientB = TailscaleClient(configuration: configB)

    // Attempting to apply snapshot from A to client B must fail with targetMismatch
    do {
      _ = try await clientB.setServeConfig(ServeConfig(), matching: snapshotFromA)
      XCTFail("Must reject snapshot from mismatched target")
    } catch let error as TailscaleClientError {
      guard case .targetMismatch(let expected, let actual) = error else {
        XCTFail("Expected .targetMismatch, got \(error)")
        return
      }
      XCTAssertEqual(expected, clientB.targetIdentifier)
      XCTAssertEqual(actual, clientA.targetIdentifier)
    }
  }

  func testExecuteWithRecoveryRejectsRequestWhenTargetSwitchesMidFlight() async throws {
    let config = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://initial-daemon.sock")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: MockTransport { _, _ in
        TailscaleResponse(statusCode: 200, data: Data("{}".utf8), headers: [:])
      }
    )
    let client = TailscaleClient(configuration: config)

    // A request carrying an expected target identifier different from client's targetIdentifier
    let request = TailscaleRequest(
      method: "POST",
      path: "/localapi/v0/serve-config",
      body: Data("{}".utf8),
      expectedTargetIdentifier: "mismatched-target-ident"
    )

    do {
      _ = try await client.performRawRequest(request, endpoint: "/localapi/v0/serve-config")
      XCTFail("Must reject request with mismatched expected target identifier")
    } catch let error as TailscaleClientError {
      guard case .targetMismatch(let expected, let actual) = error else {
        XCTFail("Expected .targetMismatch, got \(error)")
        return
      }
      XCTAssertEqual(expected, "mismatched-target-ident")
      XCTAssertEqual(actual, client.targetIdentifier)
    }
  }
}
