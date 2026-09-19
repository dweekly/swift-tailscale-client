// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import Testing

@testable import TailscaleClient

#if os(macOS)
  /// Exercises the actual URLSession adapter used by standalone macOS installs.
  /// Responses depend only on each request, avoiding shared mutable test state.
  private final class LocalAPIURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url else { return }
      if url.path == "/failure" {
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        return
      }
      let status = url.path == "/denied" ? 403 : 200
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json", "X-Test": "preserved"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if url.path == "/echo" {
        let fields = [
          "method": request.httpMethod ?? "",
          "query": url.query ?? "",
          "host": request.value(forHTTPHeaderField: "Host") ?? "",
          "capability": request.value(forHTTPHeaderField: "Tailscale-Cap") ?? "",
          "auth": request.value(forHTTPHeaderField: "Authorization") ?? "",
          "custom": request.value(forHTTPHeaderField: "X-Audit") ?? "",
        ]
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(fields))
      } else {
        // Fragments split a line, include CRLF, and end without a newline.
        for fragment in ["{\"sequence\":", "1}\r\n{\"sequence\":2}\n", "{\"sequence\":3}"] {
          client?.urlProtocol(self, didLoad: Data(fragment.utf8))
        }
      }
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  struct URLSessionTransportTests {
    private func makeSession() -> URLSession {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [LocalAPIURLProtocol.self]
      return URLSession(configuration: configuration)
    }

    @Test(arguments: [false, true])
    func requestHeadersAndQuerySurviveURLSession(loopback: Bool) async throws {
      let session = makeSession()
      defer { session.invalidateAndCancel() }
      let transport = URLSessionTailscaleTransport(session: session)
      let config = TailscaleClientConfiguration(
        endpoint: loopback
          ? .loopback(host: "127.0.0.1", port: 12345)
          : .url(URL(string: "https://localapi.test")!),
        authToken: "test-token", capabilityVersion: 144, requestTimeout: .seconds(2))
      let response = try await transport.send(
        TailscaleRequest(
          method: "POST", path: "/echo", queryItems: [URLQueryItem(name: "peers", value: "false")],
          additionalHeaders: ["X-Audit": "test-reason"]), configuration: config)
      let fields = try JSONDecoder().decode([String: String].self, from: response.data)
      #expect(response.statusCode == 200)
      #expect(response.headers["X-Test"] == "preserved")
      #expect(fields["method"] == "POST")
      #expect(fields["query"] == "peers=false")
      #expect(fields["host"] == "local-tailscaled.sock")
      #expect(fields["capability"] == "144")
      #expect(fields["auth"] == "Basic " + Data(":test-token".utf8).base64EncodedString())
      #expect(fields["custom"] == "test-reason")
    }

    @Test(arguments: ["/stream", "/denied"])
    func streamingPreservesMetadataAndEveryFragment(path: String) async throws {
      let session = makeSession()
      defer { session.invalidateAndCancel() }
      let transport = URLSessionTailscaleTransport(session: session)
      let config = TailscaleClientConfiguration(
        endpoint: .loopback(host: "127.0.0.1", port: 12345), authToken: nil)
      let response = try await transport.sendStreaming(
        TailscaleRequest(path: path), configuration: config)
      #expect(response.statusCode == (path == "/denied" ? 403 : 200))
      #expect(response.headers["X-Test"] == "preserved")
      var lines: [String] = []
      for try await line in response.body {
        lines.append(String(decoding: line, as: UTF8.self))
      }
      #expect(lines == ["{\"sequence\":1}\r", "{\"sequence\":2}", "{\"sequence\":3}"])
    }

    @Test
    func unaryConnectionFailureRetainsUnderlyingCause() async throws {
      let session = makeSession()
      defer { session.invalidateAndCancel() }
      let transport = URLSessionTailscaleTransport(session: session)
      do {
        _ = try await transport.send(
          TailscaleRequest(path: "/failure"),
          configuration: TailscaleClientConfiguration(
            endpoint: .url(URL(string: "https://localapi.test")!), authToken: nil))
        Issue.record("Connection loss must throw")
      } catch TailscaleTransportError.networkFailure(let underlying) {
        #expect((underlying as? URLError)?.code == .networkConnectionLost)
      }
    }
  }
#endif
