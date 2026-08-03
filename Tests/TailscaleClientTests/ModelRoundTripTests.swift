// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

/// The response models became `Codable` (not just `Decodable`) in v0.6.0 so
/// apps and the CLI can re-serialize them (`--json` output, caching). These
/// tests pin the encode side: whatever we encode must decode back equal.
final class ModelRoundTripTests: XCTestCase {

  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder.tailscale()
    return try decoder.decode(T.self, from: encoder.encode(value))
  }

  func testStatusResponseRoundTrips() throws {
    // Whole-second dates: ISO8601 encoding drops sub-second precision, so
    // fractional inputs would not compare equal after the trip.
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let status = StatusResponse(
      version: "1.99.0",
      backendState: .running,
      tailscaleIPs: ["100.64.0.1"],
      selfNode: NodeStatus(
        id: "n1", publicKey: "nodekey:abc", hostName: "host", dnsName: "host.ts.net.",
        created: created,
        online: true,
        capabilityMap: [
          "https://tailscale.com/cap/is-admin": .null,
          "default-auto-update": .booleans([false]),
          "mixed": .raw([.string("a"), .integer(1)]),
        ]),
      peers: [
        "nodekey:peer1": NodeStatus(
          id: "n2", publicKey: "nodekey:peer1", hostName: "peer", dnsName: "peer.ts.net.")
      ],
      currentTailnet: TailnetStatus(name: "example.com", magicDNSEnabled: true),
      health: ["warning-1"])

    XCTAssertEqual(try roundTrip(status), status)
  }

  func testBackendStateOtherEncodesToKnownString() throws {
    let data = try JSONEncoder().encode(BackendState.other)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"Other\"")
  }

  func testWhoIsResponseRoundTrips() throws {
    let response = WhoIsResponse(
      node: WhoIsNode(
        id: 42, stableID: "stable42", name: "box.example.ts.net.",
        addresses: ["100.64.0.9/32"],
        hostinfo: WhoIsHostinfo(os: "linux", hostname: "box"),
        tags: ["tag:server"]),
      userProfile: UserProfile(id: 7, loginName: "admin@example.com"),
      capMap: ["cap": .strings(["x"])])

    XCTAssertEqual(try roundTrip(response), response)
  }

  func testPingResultRoundTrips() throws {
    let result = PingResult(
      ip: "100.64.0.5", nodeIP: "100.64.0.5", nodeName: "peer",
      latencySeconds: 0.0123, endpoint: "203.0.113.9:41641")
    XCTAssertEqual(try roundTrip(result), result)
  }

  // MARK: - Full-field round-trips for the worst-covered model files
  // (from the coverage report's bottom-ten list). Every field is set to a
  // non-default value so a dropped or misspelled coding key breaks equality.

  func testExitNodeSuggestionRoundTrips() throws {
    let suggestion = ExitNodeSuggestion(
      id: "nExit123",
      name: "exit.example.ts.net",
      location: NodeLocation(
        country: "Canada", countryCode: "CA", city: "Squamish", cityCode: "YSE",
        latitude: 49.7, longitude: -123.15, priority: 100))
    XCTAssertEqual(try roundTrip(suggestion), suggestion)
  }

  func testLoginProfileRoundTrips() throws {
    let profile = LoginProfile(
      id: "profile-1",
      name: "dave@example.com",
      networkProfile: NetworkProfile(
        magicDNSName: "host.tail1234.ts.net", domainName: "tail1234.ts.net",
        displayName: "example-tailnet"),
      userProfile: UserProfile(id: 12345, loginName: "dave@example.com", displayName: "Dave"),
      nodeID: "nNode123",
      controlURL: "http://127.0.0.1:8080",
      created: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(try roundTrip(profile), profile)
  }

  func testPrefsRoundTripsWithEveryField() throws {
    let prefs = Prefs(
      controlURL: "https://controlplane.tailscale.com",
      routeAll: true,
      exitNodeID: "nExit123",
      exitNodeIP: "100.100.1.1",
      exitNodeAllowLANAccess: true,
      corpDNS: true,
      runSSH: true,
      runWebClient: true,
      wantRunning: true,
      loggedOut: false,
      shieldsUp: true,
      advertiseTags: ["tag:server"],
      hostname: "custom-host",
      forceDaemon: true,
      advertiseRoutes: ["10.0.0.0/24"],
      noSNAT: true,
      netfilterMode: 2,
      operatorUser: "dave",
      profileName: "work",
      autoUpdate: AutoUpdatePrefs(check: true, apply: false),
      appConnector: AppConnectorPrefs(advertise: true),
      postureChecking: true)
    XCTAssertEqual(try roundTrip(prefs), prefs)
  }

  func testDNSModelsRoundTrip() throws {
    let resolver = DNSResolver(
      address: "https://dns.example/dns-query",
      bootstrapResolution: ["9.9.9.9"],
      useWithExitNode: true)
    let osConfig = DNSOSConfig(
      nameservers: ["100.100.100.100"], searchDomains: ["tail1234.ts.net"],
      matchDomains: ["internal.example"])
    XCTAssertEqual(try roundTrip(osConfig), osConfig)
    let query = DNSQueryResponse(bytes: Data([0x12, 0x34]), resolvers: [resolver])
    XCTAssertEqual(try roundTrip(query), query)
    let config = DNSConfig(
      resolvers: [resolver],
      routes: ["internal.example": [resolver]],
      fallbackResolvers: [DNSResolver(address: "8.8.8.8")],
      domains: ["tail1234.ts.net"],
      proxied: true,
      certDomains: ["host.tail1234.ts.net"],
      extraRecords: [DNSRecord(name: "svc.internal.example", type: "A", value: "10.1.2.3")],
      exitNodeFilteredSet: [".corp.example"])
    XCTAssertEqual(try roundTrip(config), config)
    let clear = IPForwardingCheck(warning: nil)
    XCTAssertTrue(clear.isReady)
    XCTAssertEqual(try roundTrip(clear), clear)
    let warned = IPForwardingCheck(warning: "IP forwarding is disabled")
    XCTAssertFalse(warned.isReady)
    XCTAssertEqual(try roundTrip(warned), warned)
  }

  func testServeConfigRoundTripsWithEveryField() throws {
    let handler = HTTPHandler(
      path: "/var/www", proxy: "http://127.0.0.1:3000", text: "hello",
      redirect: "https://example.com")
    let web = WebServerConfig(handlers: ["/": handler])
    let tcp = TCPPortHandler(
      https: true, http: false, tcpForward: "127.0.0.1:8080",
      terminateTLS: "host.tail1234.ts.net")
    let config = ServeConfig(
      tcp: [443: tcp],
      web: ["host.tail1234.ts.net:443": web],
      services: [
        "svc:web": ServiceConfig(tcp: [443: tcp], web: ["svc.example:443": web], tun: true)
      ],
      allowFunnel: ["host.tail1234.ts.net:443": true],
      foreground: ["session-1": ServeConfig(tcp: [8443: tcp])])
    XCTAssertFalse(config.isEmpty)
    XCTAssertEqual(try roundTrip(config), config)
    XCTAssertTrue(ServeConfig().isEmpty)
    XCTAssertEqual(try roundTrip(ServeConfig()), ServeConfig())
  }

  func testIPNNotifyRoundTripsWithEveryField() throws {
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let notify = IPNNotify(
      version: "1.99.1",
      sessionID: "sess-1",
      errMessage: "transient error",
      loginFinished: EmptyMessage(),
      state: .starting,
      browseToURL: "http://127.0.0.1:8080/register/key",
      engine: EngineStatus(rBytes: 1024, wBytes: 2048, numLive: 3, liveDERPs: 1),
      health: HealthState(warnings: [
        "warnable-code": HealthWarning(
          warningCode: "warnable-code", severity: "medium", title: "Warning",
          text: "something is off", impactsConnectivity: true)
      ]),
      suggestedExitNode: "nExit123",
      localTCPPort: 41_112,
      prefs: Prefs(controlURL: "http://127.0.0.1:8080", wantRunning: true),
      netMap: .object(["SelfNode": .object(["Name": .string("host")])]),
      incomingFiles: [
        PartialFile(
          name: "photo.jpg", started: started, declaredSize: 1000, received: 500, done: false)
      ],
      outgoingFiles: [
        OutgoingFile(
          id: "f1", peerID: "peer-1", name: "doc.pdf", started: started, declaredSize: 2000,
          sent: 2000, finished: true, succeeded: true)
      ],
      filesWaiting: EmptyMessage())
    XCTAssertEqual(try roundTrip(notify), notify)
  }

  func testIPNNotifyConveniences() {
    XCTAssertTrue(IPNNotify(filesWaiting: EmptyMessage()).hasFilesWaiting)
    XCTAssertFalse(IPNNotify().hasFilesWaiting)
    let health = HealthState(warnings: ["c": HealthWarning(warningCode: "c")])
    XCTAssertTrue(health.hasWarnings)
    XCTAssertFalse(HealthState(warnings: [:]).hasWarnings)
    XCTAssertFalse(HealthState().hasWarnings)
    XCTAssertTrue(IPNState.running.isRunning)
    XCTAssertFalse(IPNState.starting.isRunning)
    XCTAssertTrue(IPNState.needsLogin.requiresAction)
    XCTAssertTrue(IPNState.needsMachineAuth.requiresAction)
    XCTAssertFalse(IPNState.running.requiresAction)
    let states: [IPNState] = [
      .noState, .inUseOtherUser, .needsLogin, .needsMachineAuth, .stopped, .starting,
      .running, .other,
    ]
    for state in states {
      XCTAssertFalse(state.description.isEmpty)
    }
  }

  func testReloadConfigResultRoundTrips() throws {
    let result = ReloadConfigResult(reloaded: true, error: "boom")
    XCTAssertEqual(try roundTrip(result), result)
  }
}
