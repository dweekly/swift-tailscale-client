// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

#if os(macOS) || os(Linux)

  /// Exercises the full interactive login lifecycle against a hermetic
  /// headscale control plane: logout → `loginInteractive()` → `BrowseToURL`
  /// on the IPN bus → `headscale nodes register` → back to Running.
  ///
  /// Triple-gated because it expires the node's keys: on top of the usual
  /// integration and write gates it requires TAILSCALE_INTEGRATION_LOGIN=1,
  /// which only the headscale lane sets — and there as a separate, final
  /// `swift test` invocation so the rest of the suite runs against a
  /// logged-in daemon.
  final class LoginLifecycleIntegrationTests: XCTestCase {

    private var client: TailscaleClient!

    override func setUp() async throws {
      try await super.setUp()
      let env = ProcessInfo.processInfo.environment
      guard env["TAILSCALE_INTEGRATION"] == "1" else {
        throw XCTSkip("Integration tests disabled. Set TAILSCALE_INTEGRATION=1 to enable.")
      }
      guard env["TAILSCALE_INTEGRATION_WRITE"] == "1", env["TAILSCALE_INTEGRATION_LOGIN"] == "1"
      else {
        throw XCTSkip(
          "Login lifecycle needs TAILSCALE_INTEGRATION_WRITE=1 and "
            + "TAILSCALE_INTEGRATION_LOGIN=1 (hermetic headscale lane only)")
      }
      client = TailscaleClient()
    }

    func testInteractiveLoginLifecycleAgainstHeadscale() async throws {
      let before = try await client.status()
      XCTAssertEqual(
        before.backendState, .running, "precondition: the lane joins before testing")

      let stream = try await client.watchIPNBus(options: [.initialState])
      let collector = NotifyCollector()
      let watchTask = Task {
        for try await notify in stream {
          await collector.append(notify)
        }
      }
      defer { watchTask.cancel() }

      // Every wait below is checkpointed to notifications that arrive
      // *after* the action that should cause them — the watch delivers the
      // pre-logout Running state up front, and matching it later made the
      // final wait pass while the daemon was still mid-login (seen live).

      // 1. Log out; the backend drops to NeedsLogin once keys are expired.
      let afterLogout = await collector.checkpoint()
      try await client.logout()
      _ = try await collector.waitFor("NeedsLogin state after logout", after: afterLogout) {
        $0.state == .needsLogin
      }

      // 2. logout() deletes the profile, and with it the control URL — a
      //    plain loginInteractive() here would dial the default control
      //    plane (observed live: BrowseToURL pointed at login.tailscale.com,
      //    which headscale can never approve). startFreshProfile is the
      //    public API for exactly this moment.
      let loginServer =
        ProcessInfo.processInfo.environment["TAILSCALE_LOGIN_SERVER"] ?? "http://127.0.0.1:8080"
      try await client.startFreshProfile(controlURL: loginServer)

      // 3. Interactive login: the daemon asks control for an auth URL and
      //    delivers it as BrowseToURL on the bus.
      let afterLogin = await collector.checkpoint()
      try await client.loginInteractive()
      let notify = try await collector.waitFor(
        "BrowseToURL after loginInteractive", after: afterLogin
      ) {
        $0.browseToURL != nil
      }
      let authURL = try XCTUnwrap(notify.browseToURL)

      XCTAssertTrue(
        authURL.hasPrefix(loginServer),
        "auth URL must come from the seeded control server, got: \(authURL)")

      // 4. Approve the login the way a human would, minus the browser:
      //    the last path component of headscale's auth URL is the
      //    registration key that `headscale nodes register` accepts.
      let key = try XCTUnwrap(URL(string: authURL)?.lastPathComponent)
      XCTAssertFalse(key.isEmpty, "auth URL should end in a registration key: \(authURL)")
      let user = ProcessInfo.processInfo.environment["TAILSCALE_HEADSCALE_USER"] ?? "ci"
      let afterRegister = await collector.checkpoint()
      try runHeadscale(["nodes", "register", "--user", user, "--key", key])

      // 5. The bus reports Running again and a fresh status agrees.
      _ = try await collector.waitFor(
        "Running state after registration", after: afterRegister, timeout: 90
      ) {
        $0.state == .running
      }
      let after = try await client.status()
      XCTAssertEqual(after.backendState, .running)
    }

    /// Runs the headscale CLI (same container as the daemon in the hermetic
    /// lane) and fails the test with its combined output on a non-zero exit.
    private func runHeadscale(_ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["headscale"] + arguments
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let text =
          String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw LoginLifecycleFailure(
          message: "headscale \(arguments.joined(separator: " ")) "
            + "exited \(process.terminationStatus): \(text)")
      }
    }
  }

  private struct LoginLifecycleFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  /// Accumulates bus notifications so the test can await conditions with a
  /// deadline without contending over a single stream iterator. Waits are
  /// checkpointed: `waitFor(after:)` only matches notifications appended
  /// after the given ``checkpoint()``, so a stale pre-action state (like the
  /// initial Running the watch delivers up front) can never satisfy a wait.
  private actor NotifyCollector {
    private var notifications: [IPNNotify] = []

    func append(_ notify: IPNNotify) {
      notifications.append(notify)
    }

    /// The current high-water mark; pass to `waitFor(after:)` to restrict
    /// matching to notifications that arrive after this point.
    func checkpoint() -> Int {
      notifications.count
    }

    func waitFor(
      _ what: String,
      after checkpoint: Int,
      timeout: TimeInterval = 60,
      _ predicate: @Sendable (IPNNotify) -> Bool
    ) async throws -> IPNNotify {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if let match = notifications.dropFirst(checkpoint).first(where: predicate) {
          return match
        }
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      throw LoginLifecycleFailure(
        message: "Timed out after \(Int(timeout))s waiting for \(what); "
          + "saw \(notifications.count) notifications (\(checkpoint) before the checkpoint)")
    }
  }

#endif
