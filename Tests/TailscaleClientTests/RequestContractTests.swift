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
        clientError.recoverySuggestion?.contains("setAuditReason") == true,
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

  // MARK: - Audit reasons

  func testAuditReasonTravelsBase64InUpstreamHeader() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let client = makeClient(transport: transport)

    await client.setAuditReason("compliance ticket 1234")
    _ = try await client.status()
    await client.setAuditReason(nil)
    _ = try await client.status()

    let requests = await recorder.requests
    XCTAssertEqual(requests.count, 2)
    let expected = Data("compliance ticket 1234".utf8).base64EncodedString()
    XCTAssertEqual(requests[0].additionalHeaders["X-Tailscale-Reason"], expected)
    XCTAssertNil(
      requests[1].additionalHeaders["X-Tailscale-Reason"],
      "Clearing the reason must stop sending the header")
  }
}
