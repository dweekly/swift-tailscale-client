// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import TailscaleClientMocks
import XCTest

@testable import TailscaleClient

final class IPNBusStreamingTests: XCTestCase {
  private func makeClient(
    _ transport: MockTransport, timeout: Duration? = .seconds(5)
  ) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://mock.local")!),
      authToken: nil,
      requestTimeout: timeout,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  func testYieldsDecodedNotifications() async throws {
    let transport = MockTransport.scriptedStream([
      .jsonLine(#"{"Version":"1.98.9","SessionID":"abc"}"#),
      .jsonLine(#"{"State":6}"#),
    ])
    let client = makeClient(transport)

    var notifies: [IPNNotify] = []
    for try await notify in try await client.watchIPNBus() {
      notifies.append(notify)
    }

    XCTAssertEqual(notifies.count, 2)
    XCTAssertEqual(notifies.first?.version, "1.98.9")
    XCTAssertEqual(notifies.last?.state, .running)
  }

  func testMalformedLineIsSkippedAndReported() async throws {
    let transport = MockTransport.scriptedStream([
      .jsonLine(#"{"State":6}"#),
      .line(Data("not json at all".utf8)),
      .jsonLine(#"{"State":4}"#),
    ])
    let client = makeClient(transport)

    let sink = LineSink()
    let stream = try await client.watchIPNBus(onUndecodableLine: { line, error in
      sink.append(line: line, error: error)
    })

    var states: [IPNState] = []
    for try await notify in stream {
      if let state = notify.state { states.append(state) }
    }

    XCTAssertEqual(states, [.running, .stopped], "bad line must not end the stream")
    XCTAssertEqual(sink.lines.count, 1)
    XCTAssertEqual(String(decoding: sink.lines[0], as: UTF8.self), "not json at all")
    guard case .decoding = sink.errors[0] else {
      return XCTFail("expected a decoding error, got \(sink.errors[0])")
    }
  }

  func testMidStreamTransportErrorEndsStreamWithoutReconnectPolicy() async throws {
    let transport = MockTransport.scriptedStream([
      .jsonLine(#"{"State":6}"#),
      .failure(TailscaleTransportError.connectionRefused(endpoint: "mock")),
    ])
    let client = makeClient(transport)

    var received = 0
    do {
      for try await _ in try await client.watchIPNBus() {
        received += 1
      }
      XCTFail("expected the stream to throw")
    } catch let error as TailscaleClientError {
      guard case .transport(.connectionRefused) = error else {
        return XCTFail("expected transport(connectionRefused), got \(error)")
      }
    }
    XCTAssertEqual(received, 1)
  }

  func testReconnectResumesAfterDroppedConnection() async throws {
    let transport = MockTransport.scriptedStreams([
      [
        .jsonLine(#"{"State":6}"#),
        .failure(TailscaleTransportError.connectionRefused(endpoint: "mock")),
      ],
      [.jsonLine(#"{"State":4}"#)],
    ])
    let client = makeClient(transport)
    let policy = IPNBusReconnectPolicy(
      maxAttempts: 2, initialDelay: .milliseconds(5), maxDelay: .milliseconds(20))

    var states: [IPNState] = []
    do {
      for try await notify in try await client.watchIPNBus(reconnect: policy) {
        if let state = notify.state { states.append(state) }
      }
      XCTFail("expected the stream to throw once reconnect attempts are exhausted")
    } catch let error as TailscaleClientError {
      // After the second script is consumed (EOF), further redials hit the
      // exhausted script queue and the policy gives up with the last error.
      guard case .transport(.unimplemented) = error else {
        return XCTFail("expected transport(unimplemented), got \(error)")
      }
    }

    XCTAssertEqual(states, [.running, .stopped], "stream must survive the dropped connection")
  }

  func testConsumerCanStopEarlyDuringDelay() async throws {
    let transport = MockTransport.scriptedStream([
      .jsonLine(#"{"State":6}"#),
      .delay(.seconds(60)),
      .jsonLine(#"{"State":4}"#),
    ])
    let client = makeClient(transport)

    for try await notify in try await client.watchIPNBus() {
      XCTAssertEqual(notify.state, .running)
      break  // terminates the stream; the pending 60 s delay must not block the test
    }
  }

  func testInitialConnectionFailureThrows() async {
    let transport = MockTransport.streaming { _, _ in
      throw TailscaleTransportError.socketNotFound(path: "/nonexistent")
    }
    let client = makeClient(transport)

    await assertThrowsErrorAsync(try await client.watchIPNBus()) { error in
      guard let clientError = error as? TailscaleClientError,
        case .transport(.socketNotFound) = clientError
      else {
        return XCTFail("expected transport(socketNotFound), got \(error)")
      }
    }
  }

  func testReconnectPolicyBackoffCapsAtMaxDelay() {
    let policy = IPNBusReconnectPolicy(
      initialDelay: .milliseconds(100), maxDelay: .milliseconds(450))
    XCTAssertEqual(policy.delay(forAttempt: 1), .milliseconds(100))
    XCTAssertEqual(policy.delay(forAttempt: 2), .milliseconds(200))
    XCTAssertEqual(policy.delay(forAttempt: 3), .milliseconds(400))
    XCTAssertEqual(policy.delay(forAttempt: 4), .milliseconds(450))
    XCTAssertEqual(policy.delay(forAttempt: 10), .milliseconds(450))
  }

  func testNotifyDecodesPrefsFilesAndNetMap() throws {
    let json = """
      {
        "Prefs": {"WantRunning": true, "ExitNodeID": "nSTABLE1"},
        "NetMap": {"Domain": "example.ts.net", "NodeCount": 3},
        "IncomingFiles": [
          {"Name": "photo.jpg", "Started": "2026-08-02T01:02:03Z",
           "DeclaredSize": 1000, "Received": 500}
        ],
        "OutgoingFiles": [
          {"ID": "xfer1", "Name": "doc.pdf", "Started": "2026-08-02T01:02:03Z",
           "DeclaredSize": 2000, "Sent": 2000, "Finished": true, "Succeeded": true}
        ],
        "FilesWaiting": {}
      }
      """
    let notify = try JSONDecoder.tailscale().decode(IPNNotify.self, from: Data(json.utf8))

    XCTAssertEqual(notify.prefs?.wantRunning, true)
    XCTAssertEqual(notify.prefs?.exitNodeID, "nSTABLE1")
    guard case .object(let netmap) = notify.netMap else {
      return XCTFail("expected netMap object")
    }
    XCTAssertEqual(netmap["Domain"], .string("example.ts.net"))
    XCTAssertEqual(notify.incomingFiles?.count, 1)
    XCTAssertEqual(notify.incomingFiles?.first?.name, "photo.jpg")
    XCTAssertEqual(notify.incomingFiles?.first?.received, 500)
    XCTAssertNotNil(notify.incomingFiles?.first?.started)
    XCTAssertEqual(notify.outgoingFiles?.first?.succeeded, true)
    XCTAssertTrue(notify.hasFilesWaiting)

    let sparse = try JSONDecoder.tailscale().decode(
      IPNNotify.self, from: Data(#"{"State":6}"#.utf8))
    XCTAssertFalse(sparse.hasFilesWaiting)
    XCTAssertNil(sparse.prefs)
  }
}

/// Collects undecodable-line reports from the @Sendable sync callback.
private final class LineSink: @unchecked Sendable {
  private let lock = NSLock()
  private var _lines: [Data] = []
  private var _errors: [TailscaleClientError] = []

  func append(line: Data, error: TailscaleClientError) {
    lock.lock()
    defer { lock.unlock() }
    _lines.append(line)
    _errors.append(error)
  }

  var lines: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return _lines
  }

  var errors: [TailscaleClientError] {
    lock.lock()
    defer { lock.unlock() }
    return _errors
  }
}
