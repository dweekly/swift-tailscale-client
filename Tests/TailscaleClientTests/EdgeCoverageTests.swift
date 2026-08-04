// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

/// Edge-path assertions for the 85% coverage ratchet: every error case's
/// human-facing text, model encode paths, and small pure helpers that the
/// endpoint tests don't reach.
final class EdgeCoverageTests: XCTestCase {

  // MARK: - Error descriptions, recovery, bodyPreview (every arm)

  func testEveryErrorCaseHasDescriptionAndConsistentPreview() {
    let body = Data("details".utf8)
    let cases: [(TailscaleClientError, String)] = [
      (.transport(.invalidURL), "Transport error"),
      (.unexpectedStatus(code: 418, body: body, endpoint: "/t"), "HTTP 418"),
      (.endpointUnavailable(endpoint: "/t", feature: "acme"), "acme"),
      (.endpointUnavailable(endpoint: "/t", feature: nil), "unavailable"),
      (.timeout(endpoint: "/t"), "timed out"),
      (.preconditionFailed(body: body, endpoint: "/t"), "stale ETag"),
      (.permissionDenied(body: body, endpoint: "/t"), "denied"),
      (.rateLimited(retryAfterSeconds: 30, body: body, endpoint: "/t"), "retry after 30s"),
      (.rateLimited(retryAfterSeconds: nil, body: body, endpoint: "/t"), "HTTP 429"),
      (.peerNotFound(endpoint: "/t"), "no matching peer"),
    ]
    for (error, needle) in cases {
      XCTAssertTrue(
        error.description.contains(needle),
        "description for \(error) should contain '\(needle)': \(error.description)")
      XCTAssertEqual(error.errorDescription, error.description)
    }
    // bodyPreview: carried for body-bearing cases, nil otherwise.
    XCTAssertEqual(
      TailscaleClientError.preconditionFailed(body: body, endpoint: "/t").bodyPreview, "details")
    XCTAssertNil(TailscaleClientError.timeout(endpoint: "/t").bodyPreview)
    XCTAssertNil(TailscaleClientError.peerNotFound(endpoint: "/t").bodyPreview)
    // Long bodies truncate with a marker; binary bodies degrade gracefully.
    let long = TailscaleClientError.unexpectedStatus(
      code: 500, body: Data(String(repeating: "x", count: 600).utf8), endpoint: "/t")
    XCTAssertTrue(long.bodyPreview?.contains("chars total") == true)
    let binary = TailscaleClientError.unexpectedStatus(
      code: 500, body: Data([0xFF, 0xFE, 0x00]), endpoint: "/t")
    XCTAssertTrue(binary.bodyPreview?.contains("binary data") == true)
  }

  func testEveryErrorCaseRecoverySuggestion() {
    let body = Data()
    let corrupted = DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: [], debugDescription: "x"))
    let expectations: [(TailscaleClientError, String?)] = [
      (.unexpectedStatus(code: 401, body: body, endpoint: "/t"), "auth token"),
      (.unexpectedStatus(code: 404, body: body, endpoint: "/t"), "Tailscale version"),
      (.unexpectedStatus(code: 503, body: body, endpoint: "/t"), "daemon"),
      (.unexpectedStatus(code: 302, body: body, endpoint: "/t"), nil),
      (.decoding(corrupted, body: body, endpoint: "/t"), "report this issue"),
      (.endpointUnavailable(endpoint: "/t", feature: nil), "daemonFeatures"),
      (.timeout(endpoint: "/t"), "requestTimeout"),
      (.preconditionFailed(body: body, endpoint: "/t"), "Re-fetch"),
      (.permissionDenied(body: body, endpoint: "/t"), "withAuditReason"),
      (.rateLimited(retryAfterSeconds: 12, body: body, endpoint: "/t"), "12 seconds"),
      (.rateLimited(retryAfterSeconds: nil, body: body, endpoint: "/t"), "Back off"),
      (.peerNotFound(endpoint: "/t"), "tailnet"),
    ]
    for (error, needle) in expectations {
      if let needle {
        let recovery = String(describing: error.recoverySuggestion)
        XCTAssertTrue(
          error.recoverySuggestion?.contains(needle) == true,
          "recovery for \(error) should contain '\(needle)': \(recovery)")
      } else {
        XCTAssertNil(error.recoverySuggestion)
      }
    }
  }

  func testDecodingErrorSummariesNameThePath() {
    let context = DecodingError.Context(
      codingPath: [], debugDescription: "boom")
    let variants: [(DecodingError, String)] = [
      (.keyNotFound(FakeKey.value, context), "missing key"),
      (.typeMismatch(String.self, context), "type mismatch"),
      (.valueNotFound(Int.self, context), "null value"),
      (.dataCorrupted(context), "corrupted data"),
    ]
    for (decodingError, needle) in variants {
      let error = TailscaleClientError.decoding(
        decodingError, body: Data(), endpoint: "/t")
      XCTAssertTrue(error.description.contains(needle), error.description)
    }
  }

  private enum FakeKey: String, CodingKey { case value }

  // MARK: - VersionDiagnostics

  func testVersionDiagnosticsDescription() {
    let with = VersionDiagnostics(
      packageVersion: "9.9.9", capabilityVersion: 144, daemonVersion: "1.99.1")
    XCTAssertTrue(with.description.contains("9.9.9"))
    XCTAssertTrue(with.description.contains("144"))
    XCTAssertTrue(with.description.contains("1.99.1"))
    let without = VersionDiagnostics(
      packageVersion: "9.9.9", capabilityVersion: 144, daemonVersion: nil)
    XCTAssertTrue(without.description.contains("unknown"))
  }

  // MARK: - Reconnect policy backoff

  func testReconnectPolicyDelayDoublesAndCaps() {
    let policy = IPNBusReconnectPolicy(
      maxAttempts: nil, initialDelay: .seconds(1), maxDelay: .seconds(5))
    XCTAssertEqual(policy.delay(forAttempt: 1), .seconds(1))
    XCTAssertEqual(policy.delay(forAttempt: 2), .seconds(2))
    XCTAssertEqual(policy.delay(forAttempt: 3), .seconds(4))
    XCTAssertEqual(policy.delay(forAttempt: 4), .seconds(5), "must cap at maxDelay")
    XCTAssertEqual(policy.delay(forAttempt: 40), .seconds(5))
  }

  // MARK: - Model encode paths

  func testServiceModelsRoundTrip() throws {
    let service = ServiceDetails(
      name: "svc:web",
      displayName: "Web",
      addresses: ["100.100.5.1"],
      ports: ["tcp:443"],
      actions: [
        ServiceAction(
          type: "postgres", port: 5432, displayName: "DB",
          attributes: ["tailscale.com/cap/resource-name": .string("appdb")])
      ])
    let decoded = try JSONDecoder.tailscale().decode(
      ServiceDetails.self, from: JSONEncoder().encode(service))
    XCTAssertEqual(decoded, service)
  }

  func testClientVersionStatusRoundTrip() throws {
    let version = ClientVersionStatus(
      runningLatest: false, latestVersion: "1.99.2", urgentSecurityUpdate: true,
      notify: true, notifyURL: "https://example.com", notifyText: "update")
    let decoded = try JSONDecoder.tailscale().decode(
      ClientVersionStatus.self, from: JSONEncoder().encode(version))
    XCTAssertEqual(decoded, version)
  }

  func testIPNStateEncodesRawValues() throws {
    XCTAssertEqual(
      String(decoding: try JSONEncoder().encode([IPNState.running]), as: UTF8.self), "[6]")
    XCTAssertEqual(IPNState.other.rawValue, -1)
    XCTAssertFalse(IPNState.other.requiresAction)
  }

  // MARK: - Proof-path redaction edge shapes

  func testRedactedProofPathHandlesShortNames() {
    // Two components: still masked to the generic marker, never the token.
    let short = DiscoveryLog.redactedProofPath("/tmp/sameuserproof-abc")
    XCTAssertFalse(short.contains("abc"))
    XCTAssertTrue(short.contains("sameuserproof-"))
  }
}
