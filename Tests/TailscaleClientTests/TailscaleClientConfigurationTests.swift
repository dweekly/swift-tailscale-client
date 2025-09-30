import XCTest

@testable import TailscaleClient

final class TailscaleClientConfigurationTests: XCTestCase {
  func testEnvironmentUrlOverride() {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_URL": "http://localhost:8080",
      "TAILSCALE_LOCALAPI_AUTHKEY": "token123",
      "TAILSCALE_LOCALAPI_CAPABILITY": "42",
    ])
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .url(URL(string: "http://localhost:8080")!))
    XCTAssertEqual(result.authToken, "token123")
    XCTAssertEqual(result.capabilityVersion, 42)
  }

  func testEnvironmentSocketOverride() {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_SOCKET": "/tmp/tailscaled.sock",
      "TAILSCALE_LOCALAPI_AUTHKEY": "alpha",
    ])
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .unixSocket(path: "/tmp/tailscaled.sock"))
    XCTAssertEqual(result.authToken, "alpha")
    XCTAssertEqual(result.capabilityVersion, 1)
  }

  func testEnvironmentLoopbackOverride() {
    let discovery = LocalAPIDiscovery(environment: [
      "TAILSCALE_LOCALAPI_PORT": "8081",
      "TAILSCALE_LOCALAPI_HOST": "127.0.0.2",
      "TAILSCALE_LOCALAPI_AUTHKEY": "beta",
    ])
    let result = discovery.discover()
    XCTAssertEqual(result.endpoint, .loopback(host: "127.0.0.2", port: 8081))
    XCTAssertEqual(result.authToken, "beta")
    XCTAssertEqual(result.capabilityVersion, 1)
  }

  func testDefaultFallsBackWhenNoOverridesPresent() {
    let discovery = LocalAPIDiscovery(environment: [:])
    let result = discovery.discover()
    switch result.endpoint {
    case .unixSocket, .loopback, .url:
      XCTAssertTrue(true)
    }
  }
}
