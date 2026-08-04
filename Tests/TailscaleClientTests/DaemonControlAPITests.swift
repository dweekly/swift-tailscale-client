// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Wire-shape tests for the always-on daemon-control surface:
/// `services()` and the destructive `shutdownTailscaled()` (which is never
/// exercised against live daemons — these mocked tests are its coverage).
final class DaemonControlAPITests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - services()

  func testServicesDecodesMapKeyedByServiceName() async throws {
    // Shape per tailcfg.ServiceDetails at the pinned upstream revision:
    // Addrs are IP strings, Ports are ProtoPortRange TEXT forms (the type
    // implements TextMarshaler), Actions is optional with open-set types.
    let json = #"""
      {"svc:web": {"Name": "svc:web", "DisplayName": "Web",
                   "Addrs": ["100.100.5.1", "fd7a::1"],
                   "Ports": ["tcp:443", "udp:53-54"],
                   "Actions": [{"Type": "postgres", "Port": 5432,
                                "Attributes": {"tailscale.com/cap/resource-name": "appdb"}}]},
       "svc:bare": {"Name": "svc:bare"}}
      """#
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.method, "GET")
      XCTAssertEqual(request.path, "/localapi/v0/services")
      return TailscaleResponse(statusCode: 200, data: Data(json.utf8))
    }
    let services = try await makeClient(transport: transport).services()

    XCTAssertEqual(services.count, 2)
    let web = try XCTUnwrap(services["svc:web"])
    XCTAssertEqual(web.displayName, "Web")
    XCTAssertEqual(web.addresses, ["100.100.5.1", "fd7a::1"])
    XCTAssertEqual(web.ports, ["tcp:443", "udp:53-54"])
    XCTAssertEqual(web.actions.count, 1)
    XCTAssertEqual(web.actions.first?.type, "postgres")
    XCTAssertEqual(web.actions.first?.port, 5432)
    XCTAssertEqual(
      web.actions.first?.attributes?["tailscale.com/cap/resource-name"], .string("appdb"))

    // omitempty/omitzero fields absent on the wire decode as empty, not nil.
    let bare = try XCTUnwrap(services["svc:bare"])
    XCTAssertNil(bare.displayName)
    XCTAssertEqual(bare.addresses, [])
    XCTAssertEqual(bare.ports, [])
    XCTAssertEqual(bare.actions, [])
  }

  func testServicesEmptyMapDecodes() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    let services = try await makeClient(transport: transport).services()
    XCTAssertTrue(services.isEmpty)
  }

  func testServicesWithoutNetmapSurfacesThe503() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 503, data: Data("no netmap".utf8))
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).services()
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(503, _, _) = clientError
      else {
        XCTFail("Expected .unexpectedStatus(503), got \(error)")
        return
      }
    }
  }

  // MARK: - shutdownTailscaled()

  func testShutdownPostsAndAcceptsEmpty200() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data())
    }
    try await makeClient(transport: transport).shutdownTailscaled()

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/localapi/v0/shutdown")
    XCTAssertNil(request.body)
  }

  func testShutdownPolicyDenialMapsToPermissionDenied() async throws {
    // Upstream answers 403 both without write access and when the
    // AllowTailscaledRestart policy is off; either way it's the typed case.
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 403, data: Data("shutdown access denied by policy".utf8))
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).shutdownTailscaled()
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .permissionDenied(let body, let endpoint) = clientError
      else {
        XCTFail("Expected .permissionDenied, got \(error)")
        return
      }
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "shutdown access denied by policy")
      XCTAssertEqual(endpoint, "/localapi/v0/shutdown")
    }
  }
}
