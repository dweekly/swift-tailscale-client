// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import PeerDiagnosticsCore
import TailscaleClient
import XCTest

/// Drives the view model through a scripted daemon in its fixture slot, a test sleeper,
/// and a test clock. Nothing here reaches a real daemon, the file system, or the network.
@MainActor
final class PeerDiagnosticsModelTests: XCTestCase {
  let spacing = PingBurstPolicy.spacing
  let timeout = PingBurstPolicy.perPingTimeout
  let maximumAge = PingBurstPolicy.resultMaximumAge
  let debounce = statusRefreshDebounce

  var daemon: ScriptedDaemon!
  var liveDaemon: ScriptedDaemon!
  var sleeper: TestSleeper!
  var clock: TestClock!
  var liveCalls: CallCounter!
  var model: PeerDiagnosticsModel!

  func makeModel(
    status: StatusResponse = tailnet(peers: [peerA, peerB]),
    liveStatus: StatusResponse = tailnet(peers: []),
    liveError: (any Error & Sendable)? = nil,
    debounceIsImmediate: Bool = true
  ) {
    let fixture = ScriptedDaemon(status: status)
    let live = ScriptedDaemon(status: liveStatus)
    let sleeper = TestSleeper(
      immediate: debounceIsImmediate ? [spacing, debounce] : [spacing])
    let clock = TestClock()
    let counter = CallCounter()
    let environment = DiagnosticsEnvironment(
      makeFixture: { fixture },
      makeLive: { _ in
        await counter.increment()
        if let liveError { throw liveError }
        return live
      },
      now: { clock.now },
      sleep: { duration in try await sleeper.sleep(duration) }
    )
    daemon = fixture
    liveDaemon = live
    self.sleeper = sleeper
    self.clock = clock
    liveCalls = counter
    model = PeerDiagnosticsModel(environment: environment)
  }

  /// Starts the model and opens its watch with a `.connected` event.
  func startConnected() async {
    model.start()
    let daemon = self.daemon!
    await waitUntil("watch opened") { await daemon.watchOpens == 1 }
    await daemon.emit(.lifecycle(.connected))
    await waitUntil("connected") { model.connection == .connected }
  }

  /// Selects `peer`, pings it, and waits for the burst to end.
  func pingToEnd(_ peer: NodeStatus) async {
    model.select(peerID: peer.id)
    model.pingSelectedPeer()
    await waitUntil("burst ended") { !model.isPinging && model.pingResult != nil }
  }

  // MARK: - Status

  func testInitialStatusLoadsSortedPeers() async {
    makeModel()
    XCTAssertEqual(model.mode, .fixture)
    await startConnected()
    XCTAssertEqual(model.peers.map(\.name), ["example-laptop", "example-peer"])
    XCTAssertEqual(model.peers.last?.tailscaleIP, "100.64.0.2")
    XCTAssertEqual(model.peerListFreshness, .current(asOf: clock.now))
    XCTAssertEqual(model.connectionSummary, "scripted test daemon")
  }

  func testEmptyPeerList() async {
    makeModel(status: tailnet(peers: []))
    await startConnected()
    XCTAssertTrue(model.peers.isEmpty)
    XCTAssertEqual(model.peerListFreshness, .current(asOf: clock.now))
  }

  // MARK: - Ping burst

  func testBurstStopsAtDirectOnSecondReply() async throws {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.reply(derpReply), .reply(directReply)])
    await startConnected()
    await pingToEnd(peerA)
    let outcome = try XCTUnwrap(model.pingResult)
    XCTAssertEqual(
      outcome.reply, .reply(path: .direct(endpoint: "203.0.113.10:41641"), latencySeconds: 0.004))
    XCTAssertEqual(outcome.pingsSent, 2)
    XCTAssertEqual(outcome.status, .stoppedAtDirect)
    XCTAssertTrue(outcome.isSettledPath)
    let pings = await daemon.pingCalls
    XCTAssertEqual(pings.count, 2)
    let spacings = await sleeper.callCount(spacing)
    XCTAssertEqual(spacings, 1)
  }

  func testBurstReachesMaximumOnDERPAndIsNotASettledPath() async throws {
    makeModel()
    let replies = Array(repeating: ScriptedDaemon.PingStep.reply(derpReply), count: 7)
    await daemon.script(ip: "100.64.0.2", replies)
    await startConnected()
    await pingToEnd(peerA)
    let outcome = try XCTUnwrap(model.pingResult)
    XCTAssertEqual(
      outcome.reply, .reply(path: .derp(regionID: 1, regionCode: "sfo"), latencySeconds: 0.08))
    XCTAssertEqual(outcome.pingsSent, PingBurstPolicy.maximumPings)
    XCTAssertEqual(outcome.status, .reachedMaximum)
    XCTAssertFalse(outcome.isSettledPath)
    XCTAssertTrue(outcome.summary.contains("one measurement"), outcome.summary)
    let pings = await daemon.pingCalls
    XCTAssertEqual(pings.count, PingBurstPolicy.maximumPings)
  }

  func testDaemonErrorBecomesFailureText() async throws {
    makeModel()
    await daemon.script(
      ip: "100.64.0.2", [.reply(PingResult(ip: "100.64.0.2", error: "no matching peer"))])
    await startConnected()
    await pingToEnd(peerA)
    let outcome = try XCTUnwrap(model.pingResult)
    XCTAssertEqual(outcome.reply, .failure("The daemon reported: no matching peer"))
    XCTAssertEqual(outcome.status, .failed)
    XCTAssertEqual(outcome.pingsSent, 1)
  }

  func testUnansweredPingTimesOutAndEndsItsRequest() async throws {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.noReply])
    await startConnected()
    model.select(peerID: peerA.id)
    model.pingSelectedPeer()
    let sleeper = self.sleeper!
    let timeout = self.timeout
    await waitUntil("timeout armed") { await sleeper.waitingCount(timeout) == 1 }
    XCTAssertTrue(model.isPinging)
    await sleeper.release(timeout)
    // The burst can only end once the ping's task has finished, so this also shows the
    // unanswered request was cancelled rather than left running.
    await waitUntil("burst ended") { !model.isPinging }
    let outcome = try XCTUnwrap(model.pingResult)
    XCTAssertEqual(outcome.status, .failed)
    guard case .failure(let text) = outcome.reply else { return XCTFail("expected failure") }
    XCTAssertTrue(text.hasPrefix("No reply within 5 seconds"), text)
  }

  func testLateReplyCannotOverwriteNewerSelection() async throws {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.slow(directReply)])
    let bDirect = PingResult(ip: "100.64.0.3", latencySeconds: 0.01, endpoint: "203.0.113.11:41641")
    await daemon.script(ip: "100.64.0.3", [.reply(bDirect)])
    await startConnected()
    model.select(peerID: peerA.id)
    model.pingSelectedPeer()
    let daemon = self.daemon!
    await waitUntil("slow ping in flight") { await daemon.hasSlowPing }
    await pingToEnd(peerB)
    // The ping to A ignores cancellation and answers now, after the user moved on.
    await daemon.releaseSlowPing()
    try await Task.sleep(for: .milliseconds(50))
    let outcome = try XCTUnwrap(model.pingResult)
    XCTAssertEqual(outcome.peerID, peerB.id)
    XCTAssertEqual(model.selectedPeerID, peerB.id)
    XCTAssertFalse(model.isPinging)
  }

  func testPingResultGoesStaleAfterMaximumAge() async throws {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.reply(directReply)])
    await startConnected()
    await pingToEnd(peerA)
    let measuredAt = clock.now
    XCTAssertEqual(model.pingFreshness, .current(asOf: measuredAt))
    let sleeper = self.sleeper!
    let maximumAge = self.maximumAge
    await waitUntil("expiry armed") { await sleeper.waitingCount(maximumAge) == 1 }
    await sleeper.release(maximumAge)
    await waitUntil("expired") { model.pingFreshness != .current(asOf: measuredAt) }
    XCTAssertEqual(model.pingFreshness, .stale(since: measuredAt.addingTimeInterval(30)))
  }

  // MARK: - Freshness across the watch

  func testDisconnectMarksPeersAndPingStale() async {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.reply(directReply)])
    await startConnected()
    await pingToEnd(peerA)
    clock.advance(seconds: 5)
    await daemon.emit(.lifecycle(.disconnected(underlying: "server_closed")))
    await waitUntil("disconnected") { model.connection == .disconnected }
    XCTAssertEqual(model.peerListFreshness, .stale(since: clock.now))
    XCTAssertEqual(model.pingFreshness, .stale(since: clock.now))
  }

  func testStateGapRereadsStatus() async {
    makeModel()
    await startConnected()
    let daemon = self.daemon!
    let before = await daemon.statusCalls
    await daemon.emit(.lifecycle(.stateGap(reason: "undecodable_line")))
    await waitUntil("status re-read") { await daemon.statusCalls == before + 1 }
  }

  func testReconnectRestoresPeersButKeepsOldPingStale() async throws {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.reply(directReply)])
    await startConnected()
    await pingToEnd(peerA)
    let measuredAt = clock.now
    await daemon.emit(.lifecycle(.retrying(attempt: 1, delay: .milliseconds(100))))
    await waitUntil("reconnecting") { model.connection == .reconnecting(attempt: 1) }
    let lostAt = clock.now
    XCTAssertEqual(model.pingFreshness, .stale(since: lostAt))

    clock.advance(seconds: 10)
    let peerC = node("nC", "example-relay", ip: "100.64.0.4")
    await daemon.setStatus(tailnet(peers: [peerA, peerB, peerC]))
    await daemon.emit(.lifecycle(.connected))
    await daemon.emit(.lifecycle(.stateGap(reason: "reconnected")))
    await waitUntil("peers refreshed") { model.peers.count == 3 }
    XCTAssertEqual(model.connection, .connected)
    XCTAssertEqual(model.peerListFreshness, .current(asOf: clock.now))
    XCTAssertEqual(model.pingFreshness, .stale(since: lostAt))
    XCTAssertEqual(model.pingResult?.measuredAt, measuredAt)
    XCTAssertEqual(model.selectedPeerID, peerA.id)
  }

  func testPeerChangesArriveWithoutAnyStreamInterruption() async {
    makeModel()
    await startConnected()
    let peerC = node("nC", "example-relay", ip: "100.64.0.4")
    // A peer-change notification decodes with none of the modelled fields set.
    await daemon.setStatus(tailnet(peers: [peerA, peerB, peerC]))
    await daemon.emit(.notification(IPNNotify()))
    await waitUntil("peer added") { model.peers.count == 3 }

    let offlineB = node("nB", "example-laptop", ip: "100.64.0.3", online: false)
    await daemon.setStatus(tailnet(peers: [offlineB, peerC]))
    await daemon.emit(.notification(IPNNotify()))
    await waitUntil("peer removed") { model.peers.count == 2 }
    XCTAssertEqual(model.peers.first { $0.id == "nB" }?.isOnline, false)
    XCTAssertEqual(model.connection, .connected)
  }

  func testDebounceCoalescesNotificationsIntoOneStatusRead() async throws {
    makeModel(debounceIsImmediate: false)
    await startConnected()
    let daemon = self.daemon!
    let sleeper = self.sleeper!
    let debounce = self.debounce
    let before = await daemon.statusCalls
    for _ in 0..<5 { await daemon.emit(.notification(IPNNotify())) }
    await waitUntil("all delivered") { model.notificationsReceived == 5 }
    let debounces = await sleeper.callCount(debounce)
    XCTAssertEqual(debounces, 1)
    await sleeper.release(debounce)
    await waitUntil("one re-read") { await daemon.statusCalls == before + 1 }
    try await Task.sleep(for: .milliseconds(20))
    let after = await daemon.statusCalls
    XCTAssertEqual(after, before + 1)
  }

  func testIdentityChangeClearsSelectionAndDropsInFlightPing() async throws {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.slow(directReply)])
    await startConnected()
    model.select(peerID: peerA.id)
    model.pingSelectedPeer()
    let daemon = self.daemon!
    await waitUntil("slow ping in flight") { await daemon.hasSlowPing }
    // Same peers, but the daemon now runs as a different user (a profile switch).
    await daemon.setStatus(tailnet(selfID: "nOTHER", userID: 2, peers: [peerA, peerB]))
    await daemon.emit(.notification(IPNNotify()))
    await waitUntil("selection cleared") { model.selectedPeerID == nil }
    XCTAssertFalse(model.isPinging)
    await daemon.releaseSlowPing()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(model.pingResult)
    XCTAssertEqual(model.pingFreshness, .unknown)
  }

  // MARK: - Lifecycle

  func testStopCancelsWatchAndBurst() async {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.noReply])
    await startConnected()
    model.select(peerID: peerA.id)
    model.pingSelectedPeer()
    let sleeper = self.sleeper!
    let timeout = self.timeout
    let daemon = self.daemon!
    await waitUntil("ping in flight") { await sleeper.waitingCount(timeout) == 1 }
    model.stop()
    model.stop()
    XCTAssertEqual(model.connection, .stopped)
    XCTAssertFalse(model.isPinging)
    await waitUntil("watch closed") { await daemon.activeWatches == 0 }
    await waitUntil("timeout released") { await sleeper.waitingCount(timeout) == 0 }
    XCTAssertEqual(model.peerListFreshness, .stale(since: clock.now))
  }

  func testStartStopStartLeavesOneWatcher() async {
    makeModel()
    model.start()
    model.start()
    let daemon = self.daemon!
    await waitUntil("first watch") { await daemon.watchOpens == 1 }
    model.stop()
    model.start()
    model.start()
    await waitUntil("second watch") { await daemon.watchOpens == 2 }
    await waitUntil("one active") { await daemon.activeWatches == 1 }
    try? await Task.sleep(for: .milliseconds(20))
    let opens = await daemon.watchOpens
    XCTAssertEqual(opens, 2)
  }

  func testSwitchingModesLeavesOneWatcherAndNoFixtureData() async {
    makeModel(liveStatus: tailnet(peers: [node("nL", "live-peer", ip: "100.64.0.9")]))
    await startConnected()
    model.select(peerID: peerA.id)
    let fixture = self.daemon!
    let live = self.liveDaemon!
    model.switchMode(to: .live)
    XCTAssertEqual(model.mode, .live)
    XCTAssertTrue(model.peers.isEmpty)
    XCTAssertNil(model.selectedPeerID)
    await waitUntil("live peers") { model.peers.map(\.name) == ["live-peer"] }
    await waitUntil("fixture watch closed") { await fixture.activeWatches == 0 }
    await waitUntil("live watch open") { await live.activeWatches == 1 }

    model.switchMode(to: .fixture)
    await waitUntil("fixture peers") { model.peers.count == 2 }
    await waitUntil("live watch closed") { await live.activeWatches == 0 }
    await waitUntil("fixture watch open") { await fixture.activeWatches == 1 }
    let liveOpens = await live.watchOpens
    XCTAssertEqual(liveOpens, 1)
  }

  func testFixtureModeNeverCallsTheLiveSeam() async {
    makeModel()
    await daemon.script(ip: "100.64.0.2", [.reply(directReply)])
    await startConnected()
    await daemon.emit(.notification(IPNNotify()))
    await pingToEnd(peerA)
    model.stop()
    let calls = await liveCalls.count
    XCTAssertEqual(calls, 0)
  }

  func testUnreachableDaemonIsUnavailableWithActionableReason() async {
    makeModel(liveError: LocalAPIDiscoveryError.notInstalled)
    model.switchMode(to: .live)
    await waitUntil("unavailable") {
      if case .unavailable = model.connection { return true }
      return false
    }
    guard case .unavailable(let reason) = model.connection else { return }
    XCTAssertTrue(reason.contains("Install Tailscale"), reason)
  }

  func testAppStoreDiscoveryIsOffUnlessTurnedOn() async {
    var received: [Bool] = []
    let flags = FlagRecorder()
    let fixture = ScriptedDaemon(status: tailnet(peers: []))
    let environment = DiagnosticsEnvironment(
      makeFixture: { fixture },
      makeLive: { allow in
        await flags.record(allow)
        return fixture
      },
      now: { Date() },
      sleep: { _ in }
    )
    let model = PeerDiagnosticsModel(environment: environment)
    XCTAssertFalse(model.allowMacOSAppStoreDiscovery)
    model.switchMode(to: .live)
    await waitUntil("first live start") { await flags.values.count == 1 }
    model.allowMacOSAppStoreDiscovery = true
    model.restart()
    await waitUntil("second live start") { await flags.values.count == 2 }
    received = await flags.values
    XCTAssertEqual(received, [false, true])
    model.stop()
  }
}

actor FlagRecorder {
  private(set) var values: [Bool] = []
  func record(_ value: Bool) { values.append(value) }
}
