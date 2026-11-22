// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import PeerDiagnosticsCore
import TailscaleClient
import XCTest

/// A sleeper the test controls. Durations in `immediate` return at once; every other sleep
/// waits until the test calls `release(_:)` or the sleeping task is cancelled.
actor TestSleeper {
  private var immediate: Set<Duration>
  private var waiting:
    [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, Error>)] = []
  private var nextID = 0
  private(set) var calls: [Duration] = []

  init(immediate: Set<Duration>) {
    self.immediate = immediate
  }

  func sleep(_ duration: Duration) async throws {
    calls.append(duration)
    if immediate.contains(duration) {
      try Task.checkCancellation()
      return
    }
    nextID += 1
    let id = nextID
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiting.append((id, duration, continuation))
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func waitingCount(_ duration: Duration) -> Int {
    waiting.filter { $0.duration == duration }.count
  }

  func callCount(_ duration: Duration) -> Int {
    calls.filter { $0 == duration }.count
  }

  /// Ends every pending sleep of `duration`.
  func release(_ duration: Duration) {
    let due = waiting.filter { $0.duration == duration }
    waiting.removeAll { $0.duration == duration }
    for entry in due { entry.continuation.resume() }
  }

  private func cancel(_ id: Int) {
    guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
    waiting.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}

/// A daemon double whose status, pings, and watch streams are driven by the test.
actor ScriptedDaemon: DaemonConnection {
  enum PingStep: Sendable {
    /// Answer at once.
    case reply(PingResult)
    /// Never answer; ends only when the ping's task is cancelled.
    case noReply
    /// Answer with the result once the test calls `releaseSlowPing()`, ignoring
    /// cancellation, as a transport that cannot abort a request would.
    case slow(PingResult)
  }

  nonisolated let connectionSummary = "scripted test daemon"
  var currentStatus: StatusResponse
  var statusError: (any Error & Sendable)?
  private(set) var statusCalls = 0
  private(set) var pingCalls: [String] = []
  private var pingSteps: [String: [PingStep]] = [:]
  private var slowPing: CheckedContinuation<Void, Never>?
  private var watchContinuations: [AsyncThrowingStream<IPNBusEvent, Error>.Continuation] = []
  private(set) var watchOpens = 0
  private(set) var activeWatches = 0

  init(status: StatusResponse) {
    currentStatus = status
  }

  func setStatus(_ status: StatusResponse) { currentStatus = status }
  func setStatusError(_ error: (any Error & Sendable)?) { statusError = error }
  func script(ip: String, _ steps: [PingStep]) { pingSteps[ip] = steps }
  var hasSlowPing: Bool { slowPing != nil }
  func releaseSlowPing() {
    slowPing?.resume()
    slowPing = nil
  }

  func status() async throws -> StatusResponse {
    statusCalls += 1
    if let statusError { throw statusError }
    return currentStatus
  }

  func ping(ip: String) async throws -> PingResult {
    pingCalls.append(ip)
    var steps = pingSteps[ip] ?? []
    let step =
      steps.isEmpty ? PingStep.reply(PingResult(ip: ip, error: "unscripted")) : steps.removeFirst()
    pingSteps[ip] = steps
    switch step {
    case .reply(let result):
      return result
    case .noReply:
      try await Task.sleep(for: .seconds(3600))
      throw CancellationError()
    case .slow(let result):
      await withCheckedContinuation { slowPing = $0 }
      return result
    }
  }

  func watchEvents() async throws -> AsyncThrowingStream<IPNBusEvent, Error> {
    watchOpens += 1
    activeWatches += 1
    let (stream, continuation) = AsyncThrowingStream<IPNBusEvent, Error>.makeStream()
    continuation.onTermination = { _ in Task { await self.watchEnded() } }
    watchContinuations.append(continuation)
    return stream
  }

  private func watchEnded() { activeWatches -= 1 }

  /// Ends the most recently opened watch with `error`, as a failure the library gave up on.
  func endWatch(throwing error: any Error & Sendable) {
    watchContinuations.last?.finish(throwing: error)
  }

  /// Sends an event on the most recently opened watch.
  func emit(_ event: IPNBusEvent) {
    watchContinuations.last?.yield(event)
  }
}

/// Polls `condition` on the main actor until it holds, failing the test after `timeout`.
@MainActor
func waitUntil(
  _ description: String, timeout: Duration = .seconds(2), file: StaticString = #filePath,
  line: UInt = #line, _ condition: () async -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while !(await condition()) {
    if ContinuousClock.now >= deadline {
      XCTFail("timed out waiting for: \(description)", file: file, line: line)
      return
    }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

/// A fixed clock the test can move forward.
final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }
  func advance(seconds: TimeInterval) {
    lock.lock()
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }
}

/// Counts calls to the live factory, to prove fixture mode never reaches it.
actor CallCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

func node(
  _ id: String, _ name: String, ip: String, online: Bool = true, userID: UInt64 = 1
) -> NodeStatus {
  NodeStatus(
    id: id, publicKey: "nodekey:\(id)", hostName: name, dnsName: "\(name).example.ts.net.",
    operatingSystem: "linux", userID: userID, tailscaleIPs: [ip], online: online)
}

func tailnet(
  selfID: String = "nSELF", userID: UInt64 = 1, peers: [NodeStatus]
) -> StatusResponse {
  StatusResponse(
    backendState: .running,
    selfNode: node(selfID, "this-mac", ip: "100.64.0.1", userID: userID),
    peers: Dictionary(uniqueKeysWithValues: peers.map { ($0.publicKey, $0) }),
    currentTailnet: TailnetStatus(name: "example.ts.net"))
}

let peerA = node("nA", "example-peer", ip: "100.64.0.2")
let peerB = node("nB", "example-laptop", ip: "100.64.0.3")

let derpReply = PingResult(
  ip: "100.64.0.2", latencySeconds: 0.08, endpoint: "", derpRegionID: 1, derpRegionCode: "sfo")
let directReply = PingResult(
  ip: "100.64.0.2", latencySeconds: 0.004, endpoint: "203.0.113.10:41641")
