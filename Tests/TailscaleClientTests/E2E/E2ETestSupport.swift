// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import TailscaleClient
import TailscaleClientMocks
import XCTest

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Shared test support and fixture generation utilities for the E2E test suites (Tiers 1–4).
enum E2ETestSupport {

  final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    init(_ initial: Int = 0) { self.value = initial }
    func increment() -> Int {
      lock.lock()
      defer { lock.unlock() }
      value += 1
      return value
    }
  }

  /// Creates a `TailscaleClient` configured with a mock transport.
  static func makeClient(
    transport: MockTransport,
    authToken: String? = "ts-test-token-12345",
    capabilityVersion: Int = 1
  ) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://127.0.0.1:41112")!),
      authToken: authToken,
      capabilityVersion: capabilityVersion,
      transport: transport
    )
    return TailscaleClient(configuration: configuration)
  }

  /// Convenience to create a client with a unary mock response handler.
  static func makeClient(
    handler: @escaping MockTransport.Handler
  ) -> TailscaleClient {
    let transport = MockTransport(handler: handler)
    return makeClient(transport: transport)
  }

  // MARK: - JSON Fixture Builders

  static func statusJSON(
    backendState: String = "Running",
    selfIPs: [String] = ["100.64.0.1", "fd7a:115c:a1e0::1"],
    dnsName: String = "test-node.tailnet.ts.net",
    peersCount: Int = 2
  ) -> String {
    let ips = selfIPs.map { "\"\($0)\"" }.joined(separator: ",")
    var peersJSON = ""
    if peersCount > 0 {
      let peerEntries = (1...peersCount).map { i in
        """
        "peer-\(i)-node": {
          "ID": "node-\(i)",
          "PublicKey": "nodekey:peer\(i)",
          "HostName": "peer-\(i)",
          "DNSName": "peer-\(i).tailnet.ts.net",
          "TailscaleIPs": ["100.64.0.\(10 + i)"],
          "AllowedIPs": ["100.64.0.\(10 + i)/32"],
          "Online": true
        }
        """
      }.joined(separator: ",\n")
      peersJSON = "\"Peer\": { \(peerEntries) },"
    }
    return """
      {
        "Version": "1.96.0-test",
        "BackendState": "\(backendState)",
        "Self": {
          "ID": "node-self-id",
          "PublicKey": "nodekey:self",
          "HostName": "test-node",
          "DNSName": "\(dnsName)",
          "TailscaleIPs": [\(ips)],
          "AllowedIPs": [\(ips)],
          "Online": true,
          "UserID": 1001
        },
        \(peersJSON)
        "MagicDNSSuffix": "tailnet.ts.net"
      }
      """
  }

  static func prefsJSON(
    routeAll: Bool = false,
    shieldsUp: Bool = false,
    hostname: String = "test-node"
  ) -> String {
    """
    {
      "RouteAll": \(routeAll),
      "ShieldsUp": \(shieldsUp),
      "Hostname": "\(hostname)",
      "WantRunning": true,
      "LoggedOut": false
    }
    """
  }

  static func serveConfigJSON(
    etag: String = "\"etag-initial-123\"",
    allowFunnel: Bool = true,
    proxyTarget: String = "http://127.0.0.1:8080"
  ) -> String {
    """
    {
      "TCP": {
        "443": {
          "HTTPS": true
        },
        "8443": {
          "TCPForward": "127.0.0.1:9000"
        }
      },
      "Web": {
        "test-node.tailnet.ts.net:443": {
          "Handlers": {
            "/": {
              "Proxy": "\(proxyTarget)"
            },
            "/static": {
              "Path": "/var/www/html"
            }
          }
        }
      },
      "AllowFunnel": {
        "test-node.tailnet.ts.net:443": \(allowFunnel)
      }
    }
    """
  }

  static func ipnNotifyJSON(
    state: Int = 4,  // 4 = Running
    ipnState: String = "Running",
    version: String = "1.96.0"
  ) -> String {
    """
    {
      "Version": "\(version)",
      "State": \(state),
      "IPNState": "\(ipnState)",
      "BackendLogID": "log-abc-123"
    }
    """
  }

  static func whoIsJSON(
    nodeName: String = "target-node",
    ip: String = "100.64.0.2",
    loginName: String = "user@example.com"
  ) -> String {
    """
    {
      "Node": {
        "ID": 12345,
        "Name": "\(nodeName)",
        "Addresses": ["\(ip)"],
        "AllowedIPs": ["\(ip)/32"]
      },
      "UserProfile": {
        "ID": 1002,
        "LoginName": "\(loginName)",
        "DisplayName": "Test User"
      }
    }
    """
  }

  static func derpMapJSON() -> String {
    """
    {
      "Regions": {
        "1": {
          "RegionID": 1,
          "RegionCode": "nyc",
          "RegionName": "New York City",
          "Nodes": [
            {
              "Name": "1a",
              "RegionID": 1,
              "HostName": "derp1a.tailscale.com",
              "IPv4": "198.51.100.1"
            }
          ]
        },
        "2": {
          "RegionID": 2,
          "RegionCode": "sfo",
          "RegionName": "San Francisco",
          "Nodes": [
            {
              "Name": "2a",
              "RegionID": 2,
              "HostName": "derp2a.tailscale.com",
              "IPv4": "198.51.100.2"
            }
          ]
        }
      }
    }
    """
  }

  static func profilesJSON() -> String {
    """
    [
      {
        "ID": "profile-personal",
        "Name": "Personal",
        "Key": "ts-prof-1"
      },
      {
        "ID": "profile-work",
        "Name": "Work",
        "Key": "ts-prof-2"
      }
    ]
    """
  }
}
