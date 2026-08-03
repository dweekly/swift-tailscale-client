// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tests for the v0.7.0 DNS-diagnostics surfaces: `dnsOSConfig()`,
/// `dnsQuery(name:type:)`, and `checkIPForwarding()`.
final class DNSDiagnosticsTests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - Decoding

  func testDNSOSConfigDecodesFixture() throws {
    let data = try fixture(named: "dns-osconfig-sample", type: "json")
    let config = try JSONDecoder.tailscale().decode(DNSOSConfig.self, from: data)
    XCTAssertEqual(config.nameservers, ["100.100.100.100"])
    XCTAssertEqual(config.searchDomains.count, 2)
    XCTAssertEqual(config.matchDomains.last, "ts.net.")
  }

  func testDNSOSConfigToleratesNullArrays() throws {
    let json = Data(#"{"Nameservers": null}"#.utf8)
    let config = try JSONDecoder.tailscale().decode(DNSOSConfig.self, from: json)
    XCTAssertTrue(config.nameservers.isEmpty)
    XCTAssertTrue(config.searchDomains.isEmpty)
  }

  func testDNSQueryResponseDecodesFixture() throws {
    let data = try fixture(named: "dns-query-sample", type: "json")
    let response = try JSONDecoder.tailscale().decode(DNSQueryResponse.self, from: data)

    // Go emits []byte as base64; the fixture's payload is a DNS question for
    // peer.example.ts.net. — verify the header bytes survived the trip.
    XCTAssertGreaterThan(response.bytes.count, 12, "Expected a DNS message beyond the header")
    XCTAssertEqual(response.bytes.prefix(2), Data([0xAB, 0xCD]))

    XCTAssertEqual(response.resolvers.count, 2)
    XCTAssertEqual(response.resolvers.first?.address, "100.100.100.100")
    XCTAssertEqual(response.resolvers.first?.useWithExitNode, false)
    XCTAssertEqual(response.resolvers.last?.address, "https://dns.example/dns-query")
    XCTAssertEqual(response.resolvers.last?.bootstrapResolution, ["203.0.113.53"])
    XCTAssertEqual(response.resolvers.last?.useWithExitNode, true)
  }

  func testIPForwardingCheckReadiness() throws {
    let ready = try JSONDecoder.tailscale().decode(
      IPForwardingCheck.self, from: Data("{}".utf8))
    XCTAssertTrue(ready.isReady)

    let notReady = try JSONDecoder.tailscale().decode(
      IPForwardingCheck.self,
      from: Data(#"{"Warning": "IP forwarding is disabled, subnet routing will not work"}"#.utf8))
    XCTAssertFalse(notReady.isReady)
    XCTAssertTrue(notReady.warning?.contains("disabled") ?? false)
  }

  func testDNSConfigDecodesAndRequests() async throws {
    let body = #"""
      {
        "Resolvers": [{"Addr": "1.1.1.1"}],
        "Routes": {"corp.example.com.": [{"Addr": "10.0.0.53"}]},
        "Domains": ["example.ts.net"],
        "Proxied": true,
        "CertDomains": ["host.example.ts.net"],
        "ExtraRecords": [{"Name": "vpn.example.ts.net", "Value": "100.64.0.1"}]
      }
      """#
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data(body.utf8))
    }
    let client = makeClient(transport: transport)
    let config = try await client.dnsConfig()

    XCTAssertEqual(config.resolvers.first?.address, "1.1.1.1")
    XCTAssertEqual(config.routes["corp.example.com."]?.first?.address, "10.0.0.53")
    XCTAssertTrue(config.proxied)
    XCTAssertEqual(config.certDomains, ["host.example.ts.net"])
    XCTAssertEqual(config.extraRecords.first?.name, "vpn.example.ts.net")
    XCTAssertEqual(config.extraRecords.first?.value, "100.64.0.1")

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "GET")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/dns-config")
  }

  func testDNSConfigMaps404ToEndpointUnavailable() async {
    // dns-config was added in Tailscale 1.98; the previous stable 404s it.
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("404 page not found".utf8))
    }
    let client = makeClient(transport: transport)
    await assertThrowsErrorAsync(try await client.dnsConfig()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(let endpoint, _) = clientError
      else {
        XCTFail("Expected endpointUnavailable, got \(error)")
        return
      }
      XCTAssertEqual(endpoint, "/localapi/v0/dns-config")
    }
  }

  func testDNSConfigToleratesEmptyObject() throws {
    let config = try JSONDecoder.tailscale().decode(DNSConfig.self, from: Data("{}".utf8))
    XCTAssertTrue(config.resolvers.isEmpty)
    XCTAssertTrue(config.routes.isEmpty)
    XCTAssertFalse(config.proxied)
  }

  // MARK: - Request shapes

  func testDNSOSConfigRequestShape() async throws {
    let data = try fixture(named: "dns-osconfig-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }
    let client = makeClient(transport: transport)
    _ = try await client.dnsOSConfig()

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "GET")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/dns-osconfig")
  }

  func testDNSQuerySendsNameAndType() async throws {
    let data = try fixture(named: "dns-query-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }
    let client = makeClient(transport: transport)
    _ = try await client.dnsQuery(name: "peer.example.ts.net", type: "AAAA")

    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.path, "/localapi/v0/dns-query")
    XCTAssertEqual(
      captured.first?.queryItems,
      [
        URLQueryItem(name: "name", value: "peer.example.ts.net"),
        URLQueryItem(name: "type", value: "AAAA"),
      ])
  }

  func testDNSQueryDefaultsToARecords() async throws {
    let data = try fixture(named: "dns-query-sample", type: "json")
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: data)
    }
    let client = makeClient(transport: transport)
    _ = try await client.dnsQuery(name: "peer.example.ts.net")

    let captured = await recorder.requests
    XCTAssertEqual(
      captured.first?.queryItems.last, URLQueryItem(name: "type", value: "A"))
  }

  func testDNSEndpointsMap501ToEndpointUnavailable() async {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 501, data: Data("feature not available".utf8))
    }
    let client = makeClient(transport: transport)

    await assertThrowsErrorAsync(try await client.dnsOSConfig()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(_, let feature) = clientError
      else {
        XCTFail("Expected endpointUnavailable error, got \(error)")
        return
      }
      XCTAssertEqual(feature, "dns")
    }
  }

  func testCheckIPForwardingRequestShapeAndDecoding() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data(#"{"Warning": ""}"#.utf8))
    }
    let client = makeClient(transport: transport)
    let check = try await client.checkIPForwarding()

    XCTAssertTrue(check.isReady)
    let captured = await recorder.requests
    XCTAssertEqual(captured.first?.method, "GET")
    XCTAssertEqual(captured.first?.path, "/localapi/v0/check-ip-forwarding")
  }
}
