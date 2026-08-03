// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tests for issue draft 03: the upstream LocalAPI request, capability,
/// version, and error contract.
final class RequestContractTests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - Capability provenance

  func testDefaultCapabilityIsThePinnedTestedValue() {
    // Provenance lives on the constant's doc comment; this test makes an
    // accidental bump (in either direction) a deliberate act.
    XCTAssertEqual(TailscaleClientConfiguration.defaultCapabilityVersion, 144)
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!), authToken: nil)
    XCTAssertEqual(configuration.capabilityVersion, 144)
  }

  func testCapabilityHeaderCarriesTheConfiguredValue() {
    let configuration = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 1), authToken: nil,
      capabilityVersion: 99)
    let enriched = URLSessionTailscaleTransport().enrich(
      request: TailscaleRequest(path: "/localapi/v0/status"),
      configuration: configuration)
    XCTAssertEqual(enriched.additionalHeaders["Tailscale-Cap"], "99")
  }

  func testEnvironmentOverrideStillWins() {
    let result = LocalAPIDiscovery(
      environment: [
        "TAILSCALE_LOCALAPI_SOCKET": "/tmp/x.sock",
        "TAILSCALE_LOCALAPI_CAPABILITY": "7",
      ],
      fileExists: { _ in false }
    ).discover()
    XCTAssertEqual(result.capabilityVersion, 7)
  }

  // MARK: - Tailscale-Version observation

  func testDaemonVersionIsObservedFromResponseHeaders() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200, data: Data("{}".utf8),
        headers: ["Tailscale-Version": "1.99.1"])
    }
    let client = makeClient(transport: transport)

    let before = await client.versionDiagnostics()
    XCTAssertNil(before.daemonVersion, "No version before any request completes")

    _ = try await client.status()
    let after = await client.versionDiagnostics()
    XCTAssertEqual(after.daemonVersion, "1.99.1")
    XCTAssertEqual(after.packageVersion, TailscaleClientConfiguration.packageVersion)
    XCTAssertEqual(after.capabilityVersion, 144)
  }

  func testDaemonVersionObservationIsCaseInsensitive() async throws {
    // The unix transport lowercases header names.
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200, data: Data("{}".utf8), headers: ["tailscale-version": "1.96.4"])
    }
    let client = makeClient(transport: transport)
    _ = try await client.status()
    let diagnostics = await client.versionDiagnostics()
    XCTAssertEqual(diagnostics.daemonVersion, "1.96.4")
  }

  func testVersionMismatchIsNonfatal() async throws {
    // A daemon far newer than anything we tested against must not fail
    // wire-compatible requests; the version is diagnostic metadata only.
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200, data: Data(#"{"BackendState": "Running"}"#.utf8),
        headers: ["Tailscale-Version": "99.99.99"])
    }
    let client = makeClient(transport: transport)
    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
  }

  // MARK: - Typed errors

  func testForbiddenMapsToPermissionDenied() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 403, data: Data("access denied".utf8))
    }
    await assertThrowsErrorAsync(try await self.makeClient(transport: transport).status()) {
      error in
      guard let clientError = error as? TailscaleClientError,
        case .permissionDenied(let body, let endpoint) = clientError
      else {
        XCTFail("Expected .permissionDenied, got \(error)")
        return
      }
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "access denied")
      XCTAssertEqual(endpoint, "/localapi/v0/status")
      XCTAssertTrue(
        clientError.recoverySuggestion?.contains("withAuditReason") == true,
        "403 recovery should mention the audit-reason escape hatch")
    }
  }

  func testRateLimitedCarriesRetryAfter() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 429, data: Data("slow down".utf8), headers: ["Retry-After": "42"])
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).certPEM(domain: "x.ts.net")
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .rateLimited(let retryAfter, _, let endpoint) = clientError
      else {
        XCTFail("Expected .rateLimited, got \(error)")
        return
      }
      XCTAssertEqual(retryAfter, 42)
      XCTAssertEqual(endpoint, "/localapi/v0/cert/x.ts.net")
    }
  }

  func testRateLimitedWithoutRetryAfterStillTypes() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 429, data: Data())
    }
    await assertThrowsErrorAsync(try await self.makeClient(transport: transport).status()) {
      error in
      guard let clientError = error as? TailscaleClientError,
        case .rateLimited(let retryAfter, _, _) = clientError
      else {
        XCTFail("Expected .rateLimited, got \(error)")
        return
      }
      XCTAssertNil(retryAfter)
    }
  }

  // MARK: - Retry-After parsing

  func testRetryAfterParsesDeltaSecondsOnly() {
    XCTAssertEqual(TailscaleClient.parseRetryAfter("42"), 42)
    XCTAssertEqual(TailscaleClient.parseRetryAfter("0"), 0)
    XCTAssertEqual(TailscaleClient.parseRetryAfter(" 7 "), 7)
    // RFC 9110 delta-seconds is 1*DIGIT: no sign, decimal, or exponent.
    XCTAssertNil(TailscaleClient.parseRetryAfter("-5"), "negative delta is malformed")
    XCTAssertNil(TailscaleClient.parseRetryAfter("+5"), "signed delta is malformed")
    XCTAssertNil(TailscaleClient.parseRetryAfter("1.5"), "fractional delta is malformed")
    XCTAssertNil(TailscaleClient.parseRetryAfter("1e3"), "exponent form is malformed")
    XCTAssertNil(TailscaleClient.parseRetryAfter("inf"), "non-finite must not parse")
    XCTAssertNil(TailscaleClient.parseRetryAfter("nan"), "non-finite must not parse")
    XCTAssertNil(TailscaleClient.parseRetryAfter("1e999"), "overflow to inf must not parse")
    XCTAssertNil(
      TailscaleClient.parseRetryAfter(String(repeating: "9", count: 400)),
      "digit runs that overflow Double must not surface a non-finite delay")
    XCTAssertNil(TailscaleClient.parseRetryAfter("soon"), "garbage must not parse")
    XCTAssertNil(TailscaleClient.parseRetryAfter(""), "empty must not parse")
  }

  func testRetryAfterParsesAllThreeHTTPDateForms() throws {
    let now = Date(timeIntervalSince1970: 784_111_777)  // Sun, 06 Nov 1994 08:49:37 GMT
    let future = try XCTUnwrap(
      TailscaleClient.parseRetryAfter("Sun, 06 Nov 1994 08:50:37 GMT", now: now))
    XCTAssertEqual(future, 60, accuracy: 1)
    let past = try XCTUnwrap(
      TailscaleClient.parseRetryAfter("Sun, 06 Nov 1994 08:00:00 GMT", now: now))
    XCTAssertEqual(past, 0, "a date in the past means retry now, never negative")
    // RFC 9110 §5.6.7: recipients must also accept the obsolete forms.
    let rfc850 = try XCTUnwrap(
      TailscaleClient.parseRetryAfter("Sunday, 06-Nov-94 08:50:37 GMT", now: now),
      "obsolete RFC 850 dates must parse")
    XCTAssertEqual(rfc850, 60, accuracy: 1)
    let asctime = try XCTUnwrap(
      TailscaleClient.parseRetryAfter("Sun Nov  6 08:50:37 1994", now: now),
      "obsolete asctime dates (space-padded day) must parse")
    XCTAssertEqual(asctime, 60, accuracy: 1)
    XCTAssertNil(TailscaleClient.parseRetryAfter("Sun, 32 Foo 1994 99:99:99 GMT"))
  }

  func testMalformedRetryAfterYieldsNilNotCrash() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 429, data: Data(), headers: ["Retry-After": "-42e999banana"])
    }
    await assertThrowsErrorAsync(try await self.makeClient(transport: transport).status()) {
      error in
      guard let clientError = error as? TailscaleClientError,
        case .rateLimited(let retryAfter, _, _) = clientError
      else {
        XCTFail("Expected .rateLimited, got \(error)")
        return
      }
      XCTAssertNil(retryAfter)
      XCTAssertNotNil(clientError.description)
      XCTAssertNotNil(clientError.recoverySuggestion)
    }
  }

  func testHugeRetryAfterFormatsWithoutTrapping() {
    // Int(Double) traps beyond Int64 range; description must stay total.
    let error = TailscaleClientError.rateLimited(
      retryAfterSeconds: 1e30, body: Data(), endpoint: "/localapi/v0/status")
    XCTAssertTrue(error.description.contains("HTTP 429"))
    XCTAssertNotNil(error.recoverySuggestion)
  }

  // MARK: - Typed peer-not-found (distinct from optional-endpoint 404)

  func testWhois404MapsToPeerNotFound() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("peer not found".utf8))
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).whois(address: "100.64.0.99")
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .peerNotFound(let endpoint) = clientError
      else {
        XCTFail("Expected .peerNotFound, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/whois")
      XCTAssertNotNil(clientError.recoverySuggestion)
    }
  }

  func testOptionalEndpoint404StillMapsToEndpointUnavailable() async throws {
    // The same status on an optional surface keeps its distinct meaning:
    // the endpoint (not a peer) is absent.
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data())
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).certDomains()
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable = clientError
      else {
        XCTFail("Expected .endpointUnavailable, got \(error)")
        return
      }
    }
  }

  // MARK: - Audit reasons (task-local scope)

  func testAuditReasonTravelsBase64InUpstreamHeader() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = makeClient(transport: transport)

    try await TailscaleClient.withAuditReason("compliance ticket 1234") {
      _ = try await client.status()
    }
    _ = try await client.status()

    let requests = await recorder.requests
    XCTAssertEqual(requests.count, 2)
    let expected = Data("compliance ticket 1234".utf8).base64EncodedString()
    XCTAssertEqual(requests[0].additionalHeaders["X-Tailscale-Reason"], expected)
    XCTAssertNil(
      requests[1].additionalHeaders["X-Tailscale-Reason"],
      "Outside the scope the header must not be sent")
  }

  func testConcurrentTasksCarryIndependentAuditReasons() async throws {
    // The regression the task-local design exists to prevent: two concurrent
    // operations with different justifications (plus one with none) must
    // each send exactly their own. Requests are told apart by the whois
    // address they query.
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = makeClient(transport: transport)

    async let first = try TailscaleClient.withAuditReason("reason-A") {
      try await client.whois(address: "100.64.0.1")
    }
    async let second = try TailscaleClient.withAuditReason("reason-B") {
      try await client.whois(address: "100.64.0.2")
    }
    async let third = try client.whois(address: "100.64.0.3")
    _ = try await (first, second, third)

    let requests = await recorder.requests
    XCTAssertEqual(requests.count, 3)
    func reason(forAddress address: String) -> String? {
      requests.first(where: { request in
        request.queryItems.contains(URLQueryItem(name: "addr", value: address))
      })?.additionalHeaders["X-Tailscale-Reason"]
    }
    XCTAssertEqual(
      reason(forAddress: "100.64.0.1"), Data("reason-A".utf8).base64EncodedString())
    XCTAssertEqual(
      reason(forAddress: "100.64.0.2"), Data("reason-B".utf8).base64EncodedString())
    XCTAssertNil(
      reason(forAddress: "100.64.0.3"),
      "A task outside any withAuditReason scope must not inherit a reason")
  }
}
