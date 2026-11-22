// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation

/// The fixed state the committed screenshot shows, reproducible on every run.
///
/// The fixture tailnet with ``FixtureDaemon/showcasePeerName`` selected after its burst
/// ended (a DERP reply, then a direct one: two pings). The clock is frozen at ``date`` so
/// every time on screen is the same from run to run, and waits inside the burst return at
/// once so preparing the state takes milliseconds instead of seconds.
public enum SnapshotScenario {
  /// The moment every timestamp in the picture shows: 2026-01-15 17:30:00 UTC.
  public static let date = Date(timeIntervalSince1970: 1_768_498_200)
  /// The time zone the picture's clock times are written in, so they do not depend on
  /// the machine that renders it.
  public static let timeZone = TimeZone(identifier: "UTC")!
  /// Longest the preparation may take before it is reported as failed.
  public static let preparationTimeout: Duration = .seconds(10)
  /// How often preparation checks the model while waiting.
  static let pollInterval: Duration = .milliseconds(5)

  /// A fixture-only environment with a frozen clock.
  ///
  /// Sleeps shorter than ``PingBurstPolicy/perPingTimeout`` (the spacing between pings and
  /// the status-refresh debounce) end at once. Longer ones (the per-ping timeout and the
  /// result's maximum age) really wait, so a fast fixture reply always wins the timeout
  /// race and the result is still current when the picture is taken.
  public static var environment: DiagnosticsEnvironment {
    let frozen = date
    let shortest = PingBurstPolicy.perPingTimeout
    return DiagnosticsEnvironment(
      makeFixture: { FixtureDaemon() },
      makeLive: { _ in throw SnapshotError.liveModeUnavailable },
      now: { frozen },
      sleep: { duration in
        if duration < shortest {
          await Task.yield()
          try Task.checkCancellation()
        } else {
          try await Task.sleep(for: duration)
        }
      }
    )
  }

  /// Why the scenario could not be prepared.
  public enum SnapshotError: Error, Equatable {
    /// The snapshot environment never reaches a real daemon.
    case liveModeUnavailable
    /// The model did not reach the expected state in time; the text says which step.
    case timedOut(String)
  }

  /// Starts a fixture model, selects the showcase peer, runs its burst to the end, and
  /// returns the model, still started so its state stays current while it is drawn.
  @MainActor
  public static func prepareModel() async throws -> PeerDiagnosticsModel {
    let model = PeerDiagnosticsModel(environment: environment)
    model.start()
    try await waitUntil("connected with peers") {
      model.connection == .connected && !model.peers.isEmpty
    }
    guard let peer = model.peers.first(where: { $0.name == FixtureDaemon.showcasePeerName })
    else { throw SnapshotError.timedOut("showcase peer missing") }
    model.select(peerID: peer.id)
    model.pingSelectedPeer()
    try await waitUntil("ping burst ended") { !model.isPinging && model.pingResult != nil }
    return model
  }

  @MainActor
  private static func waitUntil(_ step: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + preparationTimeout
    let interval = pollInterval
    while !condition() {
      if ContinuousClock.now >= deadline { throw SnapshotError.timedOut(step) }
      try await Task.sleep(for: interval)
    }
  }
}
