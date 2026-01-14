// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class IPNNotifyDecodingTests: XCTestCase {

  // MARK: - IPNState Tests

  func testIPNStateValues() {
    XCTAssertEqual(IPNState.noState.rawValue, 0)
    XCTAssertEqual(IPNState.inUseOtherUser.rawValue, 1)
    XCTAssertEqual(IPNState.needsLogin.rawValue, 2)
    XCTAssertEqual(IPNState.needsMachineAuth.rawValue, 3)
    XCTAssertEqual(IPNState.stopped.rawValue, 4)
    XCTAssertEqual(IPNState.starting.rawValue, 5)
    XCTAssertEqual(IPNState.running.rawValue, 6)
  }

  func testIPNStateIsRunning() {
    XCTAssertTrue(IPNState.running.isRunning)
    XCTAssertFalse(IPNState.stopped.isRunning)
    XCTAssertFalse(IPNState.needsLogin.isRunning)
  }

  func testIPNStateRequiresAction() {
    XCTAssertTrue(IPNState.needsLogin.requiresAction)
    XCTAssertTrue(IPNState.needsMachineAuth.requiresAction)
    XCTAssertFalse(IPNState.running.requiresAction)
    XCTAssertFalse(IPNState.stopped.requiresAction)
  }

  func testIPNStateDescription() {
    XCTAssertEqual(IPNState.running.description, "Running")
    XCTAssertEqual(IPNState.needsLogin.description, "NeedsLogin")
    XCTAssertEqual(IPNState.stopped.description, "Stopped")
  }

  // MARK: - EngineStatus Tests

  func testDecodeEngineStatus() throws {
    let json = """
      {
        "RBytes": 1234567890,
        "WBytes": 987654321,
        "NumLive": 5,
        "LiveDERPs": 2
      }
      """
    let data = Data(json.utf8)
    let status = try JSONDecoder().decode(EngineStatus.self, from: data)

    XCTAssertEqual(status.rBytes, 1_234_567_890)
    XCTAssertEqual(status.wBytes, 987_654_321)
    XCTAssertEqual(status.numLive, 5)
    XCTAssertEqual(status.liveDERPs, 2)
  }

  // MARK: - HealthState Tests

  func testDecodeHealthStateEmpty() throws {
    let json = "{}"
    let data = Data(json.utf8)
    let health = try JSONDecoder().decode(HealthState.self, from: data)

    XCTAssertNil(health.warnings)
    XCTAssertFalse(health.hasWarnings)
  }

  func testDecodeHealthStateWithWarnings() throws {
    let json = """
      {
        "Warnings": {
          "no-derp-connection": {
            "WarnableCode": "no-derp-connection",
            "Severity": "high",
            "Title": "No DERP connection",
            "Text": "Unable to connect to any relay server",
            "ImpactsConnectivity": true
          }
        }
      }
      """
    let data = Data(json.utf8)
    let health = try JSONDecoder().decode(HealthState.self, from: data)

    XCTAssertTrue(health.hasWarnings)
    XCTAssertEqual(health.warnings?.count, 1)

    let warning = health.warnings?["no-derp-connection"]
    XCTAssertEqual(warning?.warningCode, "no-derp-connection")
    XCTAssertEqual(warning?.severity, "high")
    XCTAssertEqual(warning?.title, "No DERP connection")
    XCTAssertEqual(warning?.impactsConnectivity, true)
  }

  // MARK: - IPNNotify Tests

  func testDecodeMinimalNotify() throws {
    let json = "{}"
    let data = Data(json.utf8)
    let notify = try JSONDecoder().decode(IPNNotify.self, from: data)

    XCTAssertNil(notify.version)
    XCTAssertNil(notify.sessionID)
    XCTAssertNil(notify.state)
    XCTAssertNil(notify.engine)
    XCTAssertNil(notify.health)
  }

  func testDecodeNotifyWithVersion() throws {
    let json = """
      {
        "Version": "1.92.3",
        "SessionID": "abc123"
      }
      """
    let data = Data(json.utf8)
    let notify = try JSONDecoder().decode(IPNNotify.self, from: data)

    XCTAssertEqual(notify.version, "1.92.3")
    XCTAssertEqual(notify.sessionID, "abc123")
  }

  func testDecodeNotifyWithState() throws {
    let json = """
      {
        "State": 6
      }
      """
    let data = Data(json.utf8)
    let notify = try JSONDecoder().decode(IPNNotify.self, from: data)

    XCTAssertEqual(notify.state, .running)
  }

  func testDecodeNotifyWithEngine() throws {
    let json = """
      {
        "Engine": {
          "RBytes": 100,
          "WBytes": 200,
          "NumLive": 3,
          "LiveDERPs": 1
        }
      }
      """
    let data = Data(json.utf8)
    let notify = try JSONDecoder().decode(IPNNotify.self, from: data)

    XCTAssertNotNil(notify.engine)
    XCTAssertEqual(notify.engine?.rBytes, 100)
    XCTAssertEqual(notify.engine?.wBytes, 200)
    XCTAssertEqual(notify.engine?.numLive, 3)
    XCTAssertEqual(notify.engine?.liveDERPs, 1)
  }

  func testDecodeNotifyWithBrowseToURL() throws {
    let json = """
      {
        "BrowseToURL": "https://login.tailscale.com/a/abc123"
      }
      """
    let data = Data(json.utf8)
    let notify = try JSONDecoder().decode(IPNNotify.self, from: data)

    XCTAssertEqual(notify.browseToURL, "https://login.tailscale.com/a/abc123")
  }

  func testDecodeNotifyWithSuggestedExitNode() throws {
    let json = """
      {
        "SuggestedExitNode": "nWPcbH1CNTRL"
      }
      """
    let data = Data(json.utf8)
    let notify = try JSONDecoder().decode(IPNNotify.self, from: data)

    XCTAssertEqual(notify.suggestedExitNode, "nWPcbH1CNTRL")
  }

  func testDecodeCompleteNotify() throws {
    let json = """
      {
        "Version": "1.92.3",
        "SessionID": "session123",
        "State": 6,
        "Engine": {
          "RBytes": 1000000,
          "WBytes": 500000,
          "NumLive": 2,
          "LiveDERPs": 1
        },
        "Health": {
          "Warnings": {}
        }
      }
      """
    let data = Data(json.utf8)
    let notify = try JSONDecoder().decode(IPNNotify.self, from: data)

    XCTAssertEqual(notify.version, "1.92.3")
    XCTAssertEqual(notify.sessionID, "session123")
    XCTAssertEqual(notify.state, .running)
    XCTAssertNotNil(notify.engine)
    XCTAssertNotNil(notify.health)
    XCTAssertFalse(notify.health?.hasWarnings ?? true)
  }

  // MARK: - NotifyWatchOpt Tests

  func testNotifyWatchOptDefaults() {
    let defaultOpts: NotifyWatchOpt = .default

    XCTAssertTrue(defaultOpts.contains(.initialState))
    XCTAssertTrue(defaultOpts.contains(.initialHealthState))
    XCTAssertTrue(defaultOpts.contains(.engineUpdates))
    XCTAssertTrue(defaultOpts.contains(.rateLimit))
    XCTAssertFalse(defaultOpts.contains(.initialNetMap))
    XCTAssertFalse(defaultOpts.contains(.initialPrefs))
  }

  func testNotifyWatchOptAllInitial() {
    let allInitial: NotifyWatchOpt = .allInitial

    XCTAssertTrue(allInitial.contains(.initialState))
    XCTAssertTrue(allInitial.contains(.initialPrefs))
    XCTAssertTrue(allInitial.contains(.initialNetMap))
    XCTAssertTrue(allInitial.contains(.initialHealthState))
    XCTAssertTrue(allInitial.contains(.initialSuggestedExitNode))
  }

  func testNotifyWatchOptRawValues() {
    XCTAssertEqual(NotifyWatchOpt.engineUpdates.rawValue, 1)
    XCTAssertEqual(NotifyWatchOpt.initialState.rawValue, 2)
    XCTAssertEqual(NotifyWatchOpt.initialPrefs.rawValue, 4)
    XCTAssertEqual(NotifyWatchOpt.initialNetMap.rawValue, 8)
    XCTAssertEqual(NotifyWatchOpt.rateLimit.rawValue, 256)
  }

  func testNotifyWatchOptCombination() {
    var opts: NotifyWatchOpt = []
    opts.insert(.initialState)
    opts.insert(.engineUpdates)

    XCTAssertEqual(opts.rawValue, 3)  // 1 + 2
    XCTAssertTrue(opts.contains(.initialState))
    XCTAssertTrue(opts.contains(.engineUpdates))
    XCTAssertFalse(opts.contains(.initialPrefs))
  }
}
