// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Combine
import Foundation
import TailscaleClient

/// Everything the model needs from the outside world, so tests can replace all of it.
public struct DiagnosticsEnvironment: Sendable {
  /// Makes the fixture connection. Must not touch the network or the file system.
  public var makeFixture: @Sendable () -> any DaemonConnection
  /// Makes the live connection. The argument is ``PeerDiagnosticsModel/allowMacOSAppStoreDiscovery``.
  public var makeLive: @Sendable (Bool) async throws -> any DaemonConnection
  /// The current time.
  public var now: @Sendable () -> Date
  /// Waits for a duration; throws if the waiting task is cancelled.
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(
    makeFixture: @escaping @Sendable () -> any DaemonConnection,
    makeLive: @escaping @Sendable (Bool) async throws -> any DaemonConnection,
    now: @escaping @Sendable () -> Date,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.makeFixture = makeFixture
    self.makeLive = makeLive
    self.now = now
    self.sleep = sleep
  }

  /// The real clock, the built-in fixture tailnet, and the library's default discovery.
  public static let standard = DiagnosticsEnvironment(
    makeFixture: { FixtureDaemon() },
    makeLive: { allowAppStore in
      try await LiveDaemon.discover(allowMacOSAppStoreDiscovery: allowAppStore)
    },
    now: { Date() },
    sleep: { duration in try await Task.sleep(for: duration) }
  )
}

/// The state behind the Peer Diagnostics window, ready to render.
///
/// Lifecycle: ``start()`` reads `status()` once and opens one watch. Every watch
/// notification, every reconnect, and every reported gap triggers a debounced re-read of
/// `status()`. ``stop()`` cancels everything the model started. Both are safe to call
/// repeatedly. The model starts in fixture mode; ``switchMode(to:)`` is the only way into
/// live mode.
@MainActor
public final class PeerDiagnosticsModel: ObservableObject {
  /// Fixture or live.
  @Published public private(set) var mode: DiagnosticsMode = .fixture
  /// The connection to the current mode's daemon.
  @Published public private(set) var connection: ConnectionState = .stopped
  /// Where the connection points, without credentials; `nil` until connected once.
  @Published public private(set) var connectionSummary: String?
  /// The peers from the latest `status()` read, sorted by name.
  @Published public private(set) var peers: [PeerSummary] = []
  /// Whether ``peers`` still describes the present.
  @Published public private(set) var peerListFreshness: Freshness = .unknown
  /// The stable ID of the selected peer.
  @Published public private(set) var selectedPeerID: String?
  /// The latest ping result for the selected peer; `nil` before the first reply.
  @Published public private(set) var pingResult: PingOutcome?
  /// Whether ``pingResult`` still describes the present. Follows its own rules: it goes
  /// stale after ``PingBurstPolicy/resultMaximumAge``, on any connection loss, and on stop.
  /// A status refresh never makes it current again; only a new ping does.
  @Published public private(set) var pingFreshness: Freshness = .unknown
  /// Whether a ping burst is running.
  @Published public private(set) var isPinging = false
  /// Look for the Mac App Store edition of Tailscale too. Off by default because macOS may
  /// ask the user for permission; takes effect the next time live mode starts.
  @Published public var allowMacOSAppStoreDiscovery = false
  /// Watch notifications received in this mode, for diagnostics and tests.
  @Published public private(set) var notificationsReceived = 0

  /// The selected peer, if it is still in the list.
  public var selectedPeer: PeerSummary? {
    peers.first { $0.id == selectedPeerID }
  }

  private let environment: DiagnosticsEnvironment
  private var daemon: (any DaemonConnection)?
  private var identity: NodeIdentity?

  // Each task below is started at most once at a time. `session` changes on every start,
  // stop, mode switch, and identity change; work started under an older value discards its
  // results instead of applying them.
  private var session = 0
  private var watchTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var refreshRequested = false
  // `burst` changes whenever a burst starts or is cancelled, so a late reply from an older
  // burst can never land on a newer selection.
  private var burst = 0
  private var burstTask: Task<Void, Never>?
  private var expiryTask: Task<Void, Never>?

  public init(environment: DiagnosticsEnvironment = .standard) {
    self.environment = environment
  }

  /// Connects to the current mode's daemon. Does nothing if already started.
  public func start() {
    guard watchTask == nil else { return }
    session += 1
    connection = .connecting
    let token = session
    watchTask = Task { [weak self] in
      await self?.runSession(token)
    }
  }

  /// Cancels the watch, any refresh, and any ping burst. Shown data is kept but marked stale.
  public func stop() {
    guard watchTask != nil else { return }
    session += 1
    watchTask?.cancel()
    watchTask = nil
    refreshTask?.cancel()
    refreshTask = nil
    refreshRequested = false
    cancelBurst()
    daemon = nil
    connection = .stopped
    markStale()
  }

  /// Switches between fixture and live data. Tears down the old mode completely (its
  /// watch, its peers, any ping) before starting the new one.
  public func switchMode(to newMode: DiagnosticsMode) {
    guard newMode != mode else { return }
    stop()
    peers = []
    peerListFreshness = .unknown
    selectedPeerID = nil
    clearPingResult()
    identity = nil
    connectionSummary = nil
    notificationsReceived = 0
    mode = newMode
    start()
  }

  /// Stops and starts again in the same mode, for example after the daemon was unavailable.
  public func restart() {
    stop()
    start()
  }

  /// Selects a peer (or clears the selection) and cancels any running burst.
  public func select(peerID: String?) {
    guard peerID != selectedPeerID else { return }
    cancelBurst()
    clearPingResult()
    selectedPeerID = peerID
  }

  /// Starts a ping burst to the selected peer, replacing any running one.
  ///
  /// Sends disco pings one at a time, ``PingBurstPolicy/spacing`` apart, and stops at the
  /// first direct reply, the first failure, or ``PingBurstPolicy/maximumPings``.
  public func pingSelectedPeer() {
    cancelBurst()
    guard let daemon, let peer = selectedPeer, let ip = peer.tailscaleIP else { return }
    let token = burst
    isPinging = true
    burstTask = Task { [weak self] in
      await self?.runBurst(token: token, daemon: daemon, peerID: peer.id, ip: ip)
    }
  }

  // MARK: - Watching and refreshing

  private func runSession(_ token: Int) async {
    let connection: any DaemonConnection
    switch mode {
    case .fixture:
      connection = environment.makeFixture()
    case .live:
      do {
        connection = try await environment.makeLive(allowMacOSAppStoreDiscovery)
      } catch {
        if token == session { self.connection = .unavailable(reason: Self.reason(for: error)) }
        return
      }
    }
    guard token == session else { return }
    daemon = connection
    connectionSummary = connection.connectionSummary

    guard await refreshStatus(token) else { return }

    let events: AsyncThrowingStream<IPNBusEvent, Error>
    do {
      events = try await connection.watchEvents()
    } catch {
      if token == session { fail(Self.reason(for: error)) }
      return
    }
    var connectedBefore = false
    do {
      for try await event in events {
        guard token == session else { return }
        handle(event, connectedBefore: &connectedBefore)
      }
      if token == session {
        fail("The Tailscale daemon closed the watch. Check that Tailscale is running, then retry.")
      }
    } catch {
      if token == session, !(error is CancellationError) { fail(Self.reason(for: error)) }
    }
  }

  private func handle(_ event: IPNBusEvent, connectedBefore: inout Bool) {
    switch event {
    case .notification:
      notificationsReceived += 1
      scheduleRefresh()
    case .lifecycle(.connected):
      connection = .connected
      if connectedBefore { scheduleRefresh() }
      connectedBefore = true
    case .lifecycle(.stateGap):
      scheduleRefresh()
    case .lifecycle(.disconnected):
      connection = .disconnected
      markStale()
    case .lifecycle(.retrying(let attempt, _)):
      connection = .reconnecting(attempt: attempt)
      markStale()
    }
  }

  /// Asks for a status re-read after ``statusRefreshDebounce``. Requests that arrive while
  /// one is waiting are folded into it; one that arrives during a read causes one more read.
  private func scheduleRefresh() {
    refreshRequested = true
    guard refreshTask == nil else { return }
    let token = session
    refreshTask = Task { [weak self] in
      await self?.runRefreshLoop(token)
    }
  }

  private func runRefreshLoop(_ token: Int) async {
    let debounce = statusRefreshDebounce
    while refreshRequested, token == session {
      do { try await environment.sleep(debounce) } catch { return }
      guard token == session else { return }
      refreshRequested = false
      _ = await refreshStatus(token)
    }
    if token == session { refreshTask = nil }
  }

  /// Reads `status()` and applies it. Returns `false` if this was the first read and it
  /// failed, in which case the connection is marked unavailable.
  private func refreshStatus(_ token: Int) async -> Bool {
    guard let daemon else { return false }
    do {
      let status = try await daemon.status()
      guard token == session else { return false }
      apply(status)
      return true
    } catch {
      guard token == session else { return false }
      if connection == .connecting {
        fail(Self.reason(for: error))
        return false
      }
      markStale()
      return true
    }
  }

  private func apply(_ status: StatusResponse) {
    let newIdentity = NodeIdentity(status)
    if let identity, identity != newIdentity {
      // A different node, user, or tailnet: nothing measured before applies any more.
      cancelBurst()
      selectedPeerID = nil
      clearPingResult()
    }
    identity = newIdentity
    peers = status.peers.values.map(PeerSummary.init).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    peerListFreshness = .current(asOf: environment.now())
    if let selectedPeerID, !peers.contains(where: { $0.id == selectedPeerID }) {
      select(peerID: nil)
    }
  }

  private func fail(_ reason: String) {
    connection = .unavailable(reason: reason)
    markStale()
  }

  /// Marks the peer list and the ping result stale, keeping the earliest "since" time.
  private func markStale() {
    let now = environment.now()
    if case .current = peerListFreshness { peerListFreshness = .stale(since: now) }
    if case .current = pingFreshness {
      pingFreshness = .stale(since: now)
      expiryTask?.cancel()
      expiryTask = nil
    }
  }

  // MARK: - Ping burst

  private func runBurst(token: Int, daemon: any DaemonConnection, peerID: String, ip: String) async
  {
    let policy = (max: PingBurstPolicy.maximumPings, spacing: PingBurstPolicy.spacing)
    for count in 1...policy.max {
      if count > 1 {
        do { try await environment.sleep(policy.spacing) } catch { return }
      }
      let reply = await pingOnce(daemon: daemon, ip: ip)
      guard token == burst, !Task.isCancelled else { return }
      let status: BurstStatus
      switch reply {
      case .reply(.direct, _): status = .stoppedAtDirect
      case .reply: status = count == policy.max ? .reachedMaximum : .inProgress
      case .failure: status = .failed
      }
      record(
        PingOutcome(
          peerID: peerID, reply: reply, measuredAt: environment.now(), pingsSent: count,
          status: status))
      if status != .inProgress { break }
    }
    if token == burst {
      isPinging = false
      burstTask = nil
    }
  }

  /// Sends one ping and waits at most ``PingBurstPolicy/perPingTimeout`` for it. On timeout
  /// the ping's task is cancelled, which cancels its request.
  private func pingOnce(daemon: any DaemonConnection, ip: String) async -> PingReply {
    let timeout = PingBurstPolicy.perPingTimeout
    let sleep = environment.sleep
    do {
      let result = try await withThrowingTaskGroup(of: PingResult?.self) { group in
        group.addTask { try await daemon.ping(ip: ip) }
        group.addTask {
          try await sleep(timeout)
          return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
      }
      guard let result else { return .failure(Self.noReplyText) }
      if let path = result.path { return .reply(path: path, latencySeconds: result.latencySeconds) }
      return .failure("The daemon reported: \(result.error ?? "unknown error")")
    } catch let error as TailscaleClientError {
      if case .timeout = error { return .failure(Self.noReplyText) }
      return .failure(Self.reason(for: error))
    } catch {
      return .failure(Self.reason(for: error))
    }
  }

  private static let noReplyText =
    "No reply within \(PingBurstPolicy.perPingTimeout.components.seconds) seconds. "
    + "The peer may be offline or unreachable from here."

  private func record(_ outcome: PingOutcome) {
    pingResult = outcome
    pingFreshness = .current(asOf: outcome.measuredAt)
    expiryTask?.cancel()
    let token = burst
    let maximumAge = PingBurstPolicy.resultMaximumAge
    expiryTask = Task { [weak self] in
      await self?.expire(token: token, measuredAt: outcome.measuredAt, after: maximumAge)
    }
  }

  private func expire(token: Int, measuredAt: Date, after age: Duration) async {
    do { try await environment.sleep(age) } catch { return }
    guard token == burst, pingResult?.measuredAt == measuredAt else { return }
    let seconds = Double(age.components.seconds)
    pingFreshness = .stale(since: measuredAt.addingTimeInterval(seconds))
    expiryTask = nil
  }

  private func cancelBurst() {
    burst += 1
    burstTask?.cancel()
    burstTask = nil
    isPinging = false
  }

  private func clearPingResult() {
    expiryTask?.cancel()
    expiryTask = nil
    pingResult = nil
    pingFreshness = .unknown
  }

  /// Turns an error into a sentence a user can act on, using the library's recovery text.
  static func reason(for error: Error) -> String {
    if let error = error as? LocalizedError {
      let parts = [error.errorDescription, error.recoverySuggestion].compactMap { $0 }
      if !parts.isEmpty { return parts.joined(separator: " ") }
    }
    return String(describing: error)
  }
}
