// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import PeerDiagnosticsCore
import TailscaleClient
import TailscaleClientMocks
import XCTest

/// A status reply with one peer, in the daemon's JSON shape.
func statusJSON(peerName: String) -> Data {

  Data(
    """
    {"BackendState":"Running","TailscaleIPs":["100.64.0.1"],
     "Self":{"ID":"nSELF","PublicKey":"nodekey:self","HostName":"this-mac",
             "DNSName":"this-mac.example.ts.net.","UserID":1,"TailscaleIPs":["100.64.0.1"]},
     "Peer":{"nodekey:a":{"ID":"nA","PublicKey":"nodekey:a","HostName":"\(peerName)",
             "DNSName":"\(peerName).example.ts.net.","OS":"linux","Online":true,
             "TailscaleIPs":["100.64.0.2"]}},
     "CurrentTailnet":{"Name":"example.ts.net"}}
    """.utf8)
}

/// Runs the real `LiveDaemon` over a `TailscaleClient` built on `MockTransport`, the way an
/// app would test its own code against scripted daemon responses.
@MainActor
final class LiveDaemonTests: XCTestCase {
  func testWatchUsesSubscriptionAndReconnectRereadsStatus() async throws {
    let recorder = RequestRecorder()
    let streams = MockTransport.scriptedStreams([
      // First connection: the initial notification, then a dropped connection.
      [
        .jsonLine(#"{"State":6}"#),
        .failure(TailscaleTransportError.connectionRefused(endpoint: "mock")),
      ],
      // Second connection: a peer-change notification the library does not model.
      [.jsonLine(#"{"PeerChanges":[{"NodeID":2}]}"#), .delay(.seconds(60))],
    ])
    let transport = MockTransport(
      handler: { request, _ in
        await recorder.record(request: request)
        // The peer is renamed once the watch has reconnected, so only a status read after
        // the reconnect can show the new name.
        let watches = await recorder.requests.filter { $0.path == "/localapi/v0/watch-ipn-bus" }
        return TailscaleResponse(
          statusCode: 200,
          data: statusJSON(peerName: watches.count < 2 ? "example-peer" : "example-renamed"))
      },
      streaming: { request, configuration in
        await recorder.record(request: request)
        return try await streams.sendStreaming(request, configuration: configuration)
      })
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://mock.local")!), authToken: nil, transport: transport))
    // Fast, jitter-free reconnects keep the test well under a second.
    let fastRetry = StreamRetryPolicy(
      initialDelay: .milliseconds(5), maxDelay: .milliseconds(5), jitter: 0)
    let live = LiveDaemon(client: client, retryPolicy: fastRetry)
    let environment = DiagnosticsEnvironment(
      makeFixture: { live }, makeLive: { _ in live }, now: { Date() },
      sleep: { duration in try await Task.sleep(for: duration) })
    let model = PeerDiagnosticsModel(environment: environment)

    model.start()
    await waitUntil("renamed peer after reconnect", timeout: .seconds(5)) {
      model.peers.first?.name == "example-renamed"
    }
    XCTAssertEqual(model.connection, .connected)
    if case .current = model.peerListFreshness {} else { XCTFail("peer list should be current") }
    model.stop()

    let requests = await recorder.requests
    let watch = try XCTUnwrap(requests.first { $0.path == "/localapi/v0/watch-ipn-bus" })
    let mask = watch.queryItems.first { $0.name == "mask" }?.value
    XCTAssertEqual(mask, String(peerDiagnosticsWatchOptions.rawValue))
    XCTAssertEqual(peerDiagnosticsWatchOptions.rawValue, (1 << 1) | (1 << 12) | (1 << 13))
  }
}

/// The built-in fixture tailnet that fixture mode shows.
final class FixtureDaemonTests: XCTestCase {
  func testFixtureTailnetScriptsEveryPathKind() async throws {
    let fixture = FixtureDaemon()
    let status = try await fixture.status()
    XCTAssertEqual(status.peers.count, 7)
    for peer in status.peers.values {
      for ip in peer.tailscaleIPs {
        XCTAssertTrue(ip.hasPrefix("100.64.0.") || ip.hasPrefix("2001:db8::"), ip)
      }
    }
    func path(_ ip: String) async throws -> PingPath? { try await fixture.ping(ip: ip).path }
    let direct = try await path("100.64.0.2")
    XCTAssertEqual(direct, .direct(endpoint: "203.0.113.10:41641"))
    let laptopFirst = try await path("100.64.0.3")
    XCTAssertEqual(laptopFirst, .derp(regionID: 1, regionCode: "sfo"))
    let laptopSecond = try await path("100.64.0.3")
    XCTAssertEqual(laptopSecond, .direct(endpoint: "203.0.113.11:41641"))
    let relay = try await path("100.64.0.4")
    XCTAssertEqual(relay, .peerRelay(endpoint: "203.0.113.12:7777:vni:42"))
    let unknown = try await path("100.64.0.6")
    XCTAssertEqual(unknown, .unknown)
    let broken = try await path("100.64.0.8")
    XCTAssertNil(broken)
  }
}
