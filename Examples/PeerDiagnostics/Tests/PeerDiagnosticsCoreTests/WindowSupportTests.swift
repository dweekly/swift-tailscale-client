// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import PeerDiagnosticsCore
import TailscaleClient
import XCTest

/// The command-line flags, the window's text, and the state the screenshot shows.
final class LaunchOptionsTests: XCTestCase {
  func testNoArgumentsOpensTheWindowInFixtureMode() throws {
    XCTAssertEqual(try LaunchOptions.parse([]), LaunchOptions())
  }

  func testPrintModesAreUnchanged() throws {
    XCTAssertEqual(
      try LaunchOptions.parse(["--fixture", "--print"]), LaunchOptions(action: .print))
    XCTAssertEqual(
      try LaunchOptions.parse(["--live", "--print", "--allow-app-store-discovery"]),
      LaunchOptions(action: .print, mode: .live, allowMacOSAppStoreDiscovery: true))
  }

  func testSnapshotTakesAPathAndAnAppearance() throws {
    XCTAssertEqual(
      try LaunchOptions.parse(["--fixture", "--snapshot", "out.png"]),
      LaunchOptions(action: .snapshot(path: "out.png")))
    XCTAssertEqual(
      try LaunchOptions.parse(["--snapshot", "out.png", "--appearance", "dark"]),
      LaunchOptions(action: .snapshot(path: "out.png"), appearance: .dark))
  }

  func testLiveWindowIsAnExplicitFlag() throws {
    XCTAssertEqual(try LaunchOptions.parse(["--live"]), LaunchOptions(mode: .live))
  }

  func testAppKitSettingsAreSkipped() throws {
    XCTAssertEqual(
      try LaunchOptions.parse(["-NSDocumentRevisionsDebugMode", "YES"]), LaunchOptions())
  }

  func testBadArgumentsAreRejected() {
    let cases: [([String], LaunchOptions.ParseError)] = [
      (["--bogus"], .unknownArgument("--bogus")),
      (["--snapshot"], .missingValue("--snapshot")),
      (["--snapshot", "--fixture"], .missingValue("--snapshot")),
      (["--snapshot", "a.png", "--appearance", "sepia"], .badAppearance("sepia")),
      (["--fixture", "--live"], .conflictingModes),
      (["--live", "--snapshot", "a.png"], .snapshotNeedsFixture),
      (["--print", "--snapshot", "a.png"], .conflictingActions),
    ]
    for (arguments, expected) in cases {
      XCTAssertThrowsError(try LaunchOptions.parse(arguments), "\(arguments)") { error in
        XCTAssertEqual(error as? LaunchOptions.ParseError, expected)
      }
    }
  }
}

final class DisplayTextTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 1_768_498_200)
  private let utc = TimeZone(identifier: "UTC")!

  private func outcome(_ reply: PingReply, _ status: BurstStatus, sent: Int = 1) -> PingOutcome {
    PingOutcome(peerID: "n", reply: reply, measuredAt: date, pingsSent: sent, status: status)
  }

  func testPathTitlesAreDistinctWords() {
    let titles = [
      outcome(
        .reply(path: .direct(endpoint: "203.0.113.1:41641"), latencySeconds: 0.004),
        .stoppedAtDirect),
      outcome(
        .reply(path: .peerRelay(endpoint: "203.0.113.2:7777:vni:1"), latencySeconds: nil),
        .reachedMaximum),
      outcome(
        .reply(path: .derp(regionID: 1, regionCode: "sfo"), latencySeconds: 0.08), .reachedMaximum),
      outcome(
        .reply(path: .derp(regionID: 9, regionCode: nil), latencySeconds: 0.08), .reachedMaximum),
      outcome(.reply(path: .unknown, latencySeconds: 0.03), .reachedMaximum),
      outcome(.failure("no reply"), .failed),
    ].map(\.pathTitle)
    XCTAssertEqual(
      titles, ["Direct", "Peer relay", "DERP sfo", "DERP region 9", "Unknown", "Failed"])
  }

  func testOnlyADirectEndingIsASettledPath() {
    let direct = outcome(
      .reply(path: .direct(endpoint: "203.0.113.1:41641"), latencySeconds: 0.004),
      .stoppedAtDirect, sent: 2)
    XCTAssertEqual(direct.conclusionTitle, "Settled path")
    XCTAssertEqual(direct.latencyText, "4.0 ms")
    XCTAssertEqual(direct.pingsSentText, "2 of up to \(PingBurstPolicy.maximumPings)")
    XCTAssertEqual(direct.endpoint?.label, "Endpoint")

    let derp = outcome(
      .reply(path: .derp(regionID: 1, regionCode: "sfo"), latencySeconds: 0.08), .reachedMaximum)
    XCTAssertEqual(derp.conclusionTitle, "One measurement")
    XCTAssertNil(derp.endpoint)
    let running = outcome(
      .reply(path: .derp(regionID: 1, regionCode: "sfo"), latencySeconds: nil), .inProgress)
    XCTAssertEqual(running.conclusionTitle, "Still pinging")
    XCTAssertNil(running.latencyText)
    XCTAssertEqual(outcome(.failure("x"), .failed).conclusionTitle, "Ping failed")
    let relay = outcome(
      .reply(path: .peerRelay(endpoint: "203.0.113.2:7777:vni:1"), latencySeconds: nil),
      .reachedMaximum)
    XCTAssertEqual(relay.endpoint?.label, "Relay")
  }

  func testFreshnessTextNamesTheTimeInTheGivenZone() {
    XCTAssertEqual(Freshness.unknown.text(timeZone: utc), "not read yet")
    XCTAssertEqual(Freshness.current(asOf: date).text(timeZone: utc), "current as of 17:30:00")
    XCTAssertEqual(Freshness.stale(since: date).text(timeZone: utc), "stale since 17:30:00")
    XCTAssertTrue(Freshness.stale(since: date).isStale)
    XCTAssertFalse(Freshness.current(asOf: date).isStale)
  }

  func testConnectionAndModeText() {
    XCTAssertEqual(ConnectionState.reconnecting(attempt: 2).title, "Reconnecting (attempt 2)…")
    XCTAssertEqual(ConnectionState.unavailable(reason: "x").title, "Unavailable")
    XCTAssertTrue(DiagnosticsMode.live.explanation.contains("Never changes Tailscale settings"))
    XCTAssertEqual(
      PeerSummary(
        id: "n", name: "a", isOnline: true, operatingSystem: nil, tailscaleIP: "100.64.0.9"
      )
      .detailText, "100.64.0.9")
  }
}

/// The screenshot's state, checked without drawing it.
@MainActor
final class SnapshotScenarioTests: XCTestCase {
  func testScenarioShowsTheShowcasePeerAfterItsBurst() async throws {
    let model = try await SnapshotScenario.prepareModel()
    defer { model.stop() }
    XCTAssertEqual(model.mode, .fixture)
    XCTAssertEqual(model.selectedPeer?.name, FixtureDaemon.showcasePeerName)
    XCTAssertEqual(model.suggestedPeerID(), model.selectedPeerID)
    let outcome = try XCTUnwrap(model.pingResult)
    XCTAssertEqual(outcome.pingsSent, 2, "DERP first, then direct")
    XCTAssertEqual(outcome.pathTitle, "Direct")
    XCTAssertTrue(outcome.isSettledPath)
    XCTAssertEqual(outcome.measuredAt, SnapshotScenario.date)
    XCTAssertEqual(model.pingFreshness, .current(asOf: SnapshotScenario.date))
    XCTAssertEqual(model.peerListFreshness, .current(asOf: SnapshotScenario.date))
    XCTAssertFalse(model.isPinging)
  }

  func testLiveSuggestionIsTheFirstOnlinePeerAndNeverPings() async throws {
    // Live mode backed by the fixture tailnet, so the test needs no daemon.
    var environment = SnapshotScenario.environment
    environment.makeLive = { _ in FixtureDaemon() }
    let model = PeerDiagnosticsModel(environment: environment)
    model.switchMode(to: .live)
    defer { model.stop() }
    let deadline = ContinuousClock.now + .seconds(2)
    while model.peers.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    let suggested = try XCTUnwrap(model.suggestedPeerID())
    XCTAssertEqual(suggested, model.peers.first { $0.isOnline }?.id)
    XCTAssertNotEqual(
      model.peers.first { $0.id == suggested }?.name, FixtureDaemon.showcasePeerName)
    XCTAssertNil(model.pingResult)
    XCTAssertFalse(model.isPinging)
  }

  func testEmptyDetailTextFollowsTheConnection() async throws {
    XCTAssertEqual(PeerDiagnosticsModel().emptySelectionText.title, "No peers to show")
    let model = try await SnapshotScenario.prepareModel()
    defer { model.stop() }
    model.select(peerID: nil)
    XCTAssertEqual(model.emptySelectionText.title, "No peer selected")
  }
}
