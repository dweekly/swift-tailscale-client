// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

/// Tests for the v0.10.0 serve/Funnel/certificate surfaces: `serveConfig()`,
/// `setServeConfig(_:)` (ETag concurrency), `certDomains()`,
/// `certPEM(domain:kind:minValidity:)`, `certPair(domain:minValidity:)`,
/// `setDNS(name:value:)`, and `queryFeature(_:)`.
final class ServeAPITests: XCTestCase {

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  // MARK: - ServeConfig decoding

  func testServeConfigDecodesFixture() throws {
    let data = try fixture(named: "serve-config", type: "json")
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: data)

    XCTAssertEqual(config.tcp.count, 2)
    XCTAssertEqual(config.tcp[443]?.https, true)
    XCTAssertEqual(config.tcp[10000]?.tcpForward, "127.0.0.1:8080")
    XCTAssertEqual(config.tcp[10000]?.terminateTLS, "node.tail1234.ts.net")

    let web = try XCTUnwrap(config.web["node.tail1234.ts.net:443"])
    XCTAssertEqual(web.handlers["/"]?.proxy, "http://127.0.0.1:3000")
    XCTAssertEqual(web.handlers["/static"]?.path, "/var/www/")
    XCTAssertEqual(web.handlers["/motd"]?.text, "hello from the tailnet")
    XCTAssertEqual(web.handlers["/old"]?.redirect, "https://example.com/new")

    XCTAssertEqual(config.allowFunnel["node.tail1234.ts.net:443"], true)
    XCTAssertEqual(config.foreground["session-abc123"]?.tcp[8443]?.https, true)
    XCTAssertFalse(config.isEmpty)
  }

  func testServeConfigRoundTripsThroughJSON() throws {
    let data = try fixture(named: "serve-config", type: "json")
    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: data)
    let reencoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: reencoded)
    XCTAssertEqual(decoded, redecoded)
  }

  func testEmptyServeConfigEncodesAsEmptyObject() throws {
    // omitempty parity with upstream: no empty maps on the wire, and the
    // etag never leaks into the body.
    var config = ServeConfig()
    config.etag = "\"abc123\""
    let wire = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    XCTAssertEqual(wire, "{}")
  }

  func testServeConfigSkipsNonNumericTCPKeys() throws {
    let json = Data(#"{"TCP": {"443": {"HTTPS": true}, "bogus": {"HTTP": true}}}"#.utf8)
    let config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: json)
    XCTAssertEqual(config.tcp.count, 1)
    XCTAssertEqual(config.tcp[443]?.https, true)
  }

  // MARK: - serveConfig() GET

  func testServeConfigCapturesETagHeader() async throws {
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.method, "GET")
      XCTAssertEqual(request.path, "/localapi/v0/serve-config")
      return TailscaleResponse(
        statusCode: 200, data: Data("{}".utf8), headers: ["Etag": "\"deadbeef\""])
    }
    let config = try await makeClient(transport: transport).serveConfig()
    XCTAssertEqual(config.etag, "\"deadbeef\"")
    XCTAssertTrue(config.isEmpty)
  }

  func testServeConfigCapturesLowercaseETagHeader() async throws {
    // The unix-socket transport lowercases header names.
    let transport = MockTransport { _, _ in
      TailscaleResponse(
        statusCode: 200, data: Data("null".utf8), headers: ["etag": "\"cafe\""])
    }
    let config = try await makeClient(transport: transport).serveConfig()
    XCTAssertEqual(config.etag, "\"cafe\"")
    XCTAssertTrue(config.isEmpty, "A null body must decode as the empty config")
  }

  // MARK: - setServeConfig() POST + ETag concurrency

  func testSetServeConfigSendsIfMatchAndBody() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }

    var config = ServeConfig()
    config.tcp[8080] = TCPPortHandler(tcpForward: "127.0.0.1:3000")
    config.etag = "\"deadbeef\""
    try await makeClient(transport: transport).setServeConfig(config)

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/localapi/v0/serve-config")
    XCTAssertEqual(request.additionalHeaders["If-Match"], "\"deadbeef\"")

    let body = try XCTUnwrap(request.body)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let tcp = try XCTUnwrap(object["TCP"] as? [String: Any])
    let handler = try XCTUnwrap(tcp["8080"] as? [String: Any])
    XCTAssertEqual(handler["TCPForward"] as? String, "127.0.0.1:3000")
    XCTAssertNil(object["ETag"], "The etag travels in headers, never the body")
  }

  func testSetServeConfigWithoutETagSendsEmptyIfMatch() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data())
    }
    try await makeClient(transport: transport).setServeConfig(ServeConfig())
    let requests = await recorder.requests
    XCTAssertEqual(requests.first?.additionalHeaders["If-Match"], "")
  }

  func testSetServeConfigMapsStaleETagToPreconditionFailed() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 412, data: Data("etag mismatch".utf8))
    }
    var config = ServeConfig()
    config.etag = "\"stale\""

    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).setServeConfig(config)
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .preconditionFailed(let body, let endpoint) = clientError
      else {
        XCTFail("Expected .preconditionFailed, got \(error)")
        return
      }
      XCTAssertEqual(String(decoding: body, as: UTF8.self), "etag mismatch")
      XCTAssertEqual(endpoint, "/localapi/v0/serve-config")
    }
  }

  // MARK: - Certificates

  func testCertDomainsDecodes() async throws {
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.path, "/localapi/v0/cert-domains")
      return TailscaleResponse(
        statusCode: 200, data: Data(#"["node.tail1234.ts.net"]"#.utf8))
    }
    let domains = try await makeClient(transport: transport).certDomains()
    XCTAssertEqual(domains, ["node.tail1234.ts.net"])
  }

  func testCertPEMSendsTypeAndMinValidity() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("PEM".utf8))
    }
    let data = try await makeClient(transport: transport).certPEM(
      domain: "node.tail1234.ts.net", kind: .certificate, minValidity: .seconds(3600))
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "PEM")

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.path, "/localapi/v0/cert/node.tail1234.ts.net")
    XCTAssertEqual(
      request.queryItems,
      [
        URLQueryItem(name: "type", value: "cert"),
        URLQueryItem(name: "min_validity", value: "3600s"),
      ])
  }

  func testCertPEMMaps404ToEndpointUnavailable() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 404, data: Data("404 page not found".utf8))
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).certPEM(domain: "x.ts.net")
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .endpointUnavailable(_, let feature) = clientError
      else {
        XCTFail("Expected .endpointUnavailable, got \(error)")
        return
      }
      XCTAssertEqual(feature, "acme")
    }
  }

  func testCertPairSplitsKeyAndCertificate() async throws {
    let key = "-----BEGIN PRIVATE KEY-----\nBASE64KEY\n-----END PRIVATE KEY-----\n"
    let cert =
      "-----BEGIN CERTIFICATE-----\nBASE64LEAF\n-----END CERTIFICATE-----\n"
      + "-----BEGIN CERTIFICATE-----\nBASE64CHAIN\n-----END CERTIFICATE-----\n"
    let transport = MockTransport { request, _ in
      XCTAssertEqual(
        request.queryItems.first, URLQueryItem(name: "type", value: "pair"))
      return TailscaleResponse(statusCode: 200, data: Data((key + cert).utf8))
    }

    let pair = try await makeClient(transport: transport).certPair(domain: "x.ts.net")
    XCTAssertEqual(pair.privateKeyPEM, key)
    XCTAssertEqual(pair.certificatePEM, cert)
  }

  func testCertPairFailsClosedOnUnsplittableResponse() async throws {
    let transport = MockTransport { _, _ in
      TailscaleResponse(statusCode: 200, data: Data("not a pem pair".utf8))
    }
    await assertThrowsErrorAsync(
      try await self.makeClient(transport: transport).certPair(domain: "x.ts.net")
    ) { error in
      guard let clientError = error as? TailscaleClientError,
        case .unexpectedStatus(200, _, _) = clientError
      else {
        XCTFail("Expected fail-closed .unexpectedStatus for a bad pair, got \(error)")
        return
      }
    }
  }

  // MARK: - set-dns and query-feature

  func testSetDNSSendsNameAndValue() async throws {
    let recorder = RequestRecorder()
    let transport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(statusCode: 200, data: Data("{}".utf8))
    }
    try await makeClient(transport: transport).setDNS(
      name: "_acme-challenge.node.tail1234.ts.net", value: "token123")

    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/localapi/v0/set-dns")
    XCTAssertEqual(
      request.queryItems,
      [
        URLQueryItem(name: "name", value: "_acme-challenge.node.tail1234.ts.net"),
        URLQueryItem(name: "value", value: "token123"),
      ])
  }

  func testQueryFeatureDecodes() async throws {
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.method, "POST")
      XCTAssertEqual(request.path, "/localapi/v0/query-feature")
      XCTAssertEqual(
        request.queryItems, [URLQueryItem(name: "feature", value: "funnel")])
      let json = #"{"Text": "Funnel is available.\nEnable it.", "URL": "https://x/enable"}"#
      return TailscaleResponse(statusCode: 200, data: Data(json.utf8))
    }
    let response = try await makeClient(transport: transport).queryFeature("funnel")
    XCTAssertFalse(response.complete)
    XCTAssertEqual(response.url, "https://x/enable")
    XCTAssertEqual(response.shouldWait, false)
    XCTAssertTrue(response.text?.contains("Funnel") == true)
  }

  func testQueryFeatureCompleteDecodes() throws {
    let response = try JSONDecoder.tailscale().decode(
      QueryFeatureResponse.self, from: Data(#"{"Complete": true, "ShouldWait": true}"#.utf8))
    XCTAssertTrue(response.complete)
    XCTAssertTrue(response.shouldWait)
    XCTAssertNil(response.text)
  }
}
