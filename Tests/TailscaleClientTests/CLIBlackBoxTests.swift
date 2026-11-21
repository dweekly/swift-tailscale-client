// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import TailscaleClient
import XCTest

#if canImport(Darwin) || os(Linux)
  /// Black-box tests that run the built `tailscale-swift` binary against a
  /// fault Unix server — the only way to regression-test CLI behavior
  /// (timeouts, output framing) at its real boundary.
  final class CLIBlackBoxTests: XCTestCase {

    private func binaryURL() throws -> URL {
      var candidates: [URL] = []
      #if canImport(Darwin)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
          candidates.append(
            bundle.bundleURL.deletingLastPathComponent()
              .appendingPathComponent("tailscale-swift"))
        }
      #endif
      candidates.append(Bundle.main.bundleURL.appendingPathComponent("tailscale-swift"))
      for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        return url
      }
      throw XCTSkip("tailscale-swift binary not present in products directory")
    }

    private struct CLIResult {
      let status: Int32
      let stdout: String
      let stderr: String
    }

    private func runCLI(
      _ arguments: [String], socketPath: String, deadline: TimeInterval
    ) throws -> CLIResult {
      let process = Process()
      process.executableURL = try binaryURL()
      process.arguments = arguments
      var environment = ProcessInfo.processInfo.environment
      environment["TAILSCALE_LOCALAPI_SOCKET"] = socketPath
      process.environment = environment

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      try process.run()

      let start = Date()
      while process.isRunning {
        if Date().timeIntervalSince(start) > deadline {
          process.terminate()
          XCTFail("CLI \(arguments) exceeded its \(deadline)s deadline")
          break
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
      process.waitUntilExit()

      let stdout = String(
        decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      let stderr = String(
        decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      return CLIResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    func testLoginRejectsNonPositiveTimeout() throws {
      let result = try runCLI(
        ["login", "--timeout", "0"],
        socketPath: NSTemporaryDirectory() + "unused.sock",
        deadline: 10)
      XCTAssertEqual(result.status, 1)
      XCTAssertTrue(result.stdout.contains("must be positive"), result.stdout)
    }

    func testLoginTimesOutWhenBusStaysSilent() throws {
      // Connection 1: the IPN bus watch — valid head, then eternal silence.
      // Connection 2: the login-interactive POST — clean 204.
      let server = try FaultUnixServer(behaviors: [
        .respond("HTTP/1.1 200 OK\r\n\r\n", closeAfterWrite: false),
        .respond("HTTP/1.1 204 No Content\r\n\r\n", closeAfterWrite: true),
      ])
      defer { server.stop() }

      let start = Date()
      let result = try runCLI(
        ["login", "--timeout", "1"], socketPath: server.path, deadline: 20)
      XCTAssertEqual(result.status, 1, "A silent bus must produce a timeout failure")
      XCTAssertTrue(result.stdout.contains("did not complete"), result.stdout)
      XCTAssertLessThan(
        Date().timeIntervalSince(start), 15,
        "login --timeout 1 must not hang awaiting notifications")
    }

    func testWatchJSONEmitsParseableNDJSONWithQuietStdout() throws {
      let body = "{\"Version\":\"x1\"}\n{\"Version\":\"x2\"}\n"
      let server = try FaultUnixServer(behaviors: [
        .respond("HTTP/1.1 200 OK\r\n\r\n" + body, closeAfterWrite: true)
      ])
      defer { server.stop() }

      let result = try runCLI(["watch", "--json"], socketPath: server.path, deadline: 20)
      XCTAssertEqual(result.status, 0, result.stderr)

      let lines = result.stdout.split(separator: "\n").map(String.init)
      XCTAssertEqual(
        lines.count, 2, "stdout must carry exactly the NDJSON events: \(result.stdout)")
      for line in lines {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        XCTAssertNotNil(object as? [String: Any], "Each stdout line must be a JSON object")
      }
      XCTAssertFalse(
        result.stdout.contains("Watching IPN bus"),
        "Diagnostics must not pollute the JSON stream")
      XCTAssertTrue(result.stderr.contains("Stream ended"), result.stderr)
    }
    // MARK: - ping

    private func runPing(_ arguments: [String], replying body: Data) throws -> CLIResult {
      let head =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        + "Content-Length: \(body.count)\r\n\r\n"
      let server = try FaultUnixServer(behaviors: [
        .respond(head + String(decoding: body, as: UTF8.self), closeAfterWrite: true)
      ])
      defer { server.stop() }
      let result = try runCLI(["ping"] + arguments, socketPath: server.path, deadline: 20)
      XCTAssertEqual(result.status, 0, result.stderr)
      return result
    }

    /// Synthetic replies: no DERP or peer-relay reply has been captured, so these follow
    /// upstream `ipnstate.PingResult`. Captured replies come from `ping-captured-*` fixtures.
    func testPingHumanOutputNamesEachPathLikeTailscalePing() throws {
      let cases: [(args: [String], body: Data, expected: String)] = [
        (
          ["100.64.0.2"], try fixture(named: "ping-captured-disco-direct", type: "json"),
          "ping 1: example-peer - 5.28 ms via [2001:db8::a]:41641"
        ),
        (
          ["100.64.0.2"],
          Data(
            #"{"NodeName":"example-peer","Err":"","LatencySeconds":0.01,"Endpoint":"","PeerRelay":"203.0.113.7:7777:vni:12","DERPRegionID":0,"DERPRegionCode":""}"#
              .utf8),
          "via peer-relay(203.0.113.7:7777:vni:12)"
        ),
        (
          ["100.64.0.2"],
          Data(
            #"{"NodeName":"example-peer","Err":"","LatencySeconds":0.08,"Endpoint":"","PeerRelay":"","DERPRegionID":1,"DERPRegionCode":"sfo"}"#
              .utf8),
          "via DERP(sfo)"
        ),
        (
          ["100.64.0.2"],
          Data(
            #"{"NodeName":"example-peer","Err":"","LatencySeconds":0.08,"DERPRegionID":7}"#.utf8),
          "via DERP(region 7)"
        ),
        (
          ["100.64.0.2", "--type", "tsmp"], try fixture(named: "ping-captured-tsmp", type: "json"),
          "ping 1: example-peer - 4.33 ms via TSMP"
        ),
        (
          ["100.64.0.2", "--type", "peerAPI"],
          try fixture(named: "ping-captured-peerapi", type: "json"), "via peerapi"
        ),
        (
          ["100.64.0.3"], try fixture(named: "ping-captured-error-expired-key", type: "json"),
          "ping 1: error - peer's node key has expired"
        ),
      ]
      for (args, body, expected) in cases {
        let result = try runPing(args, replying: body)
        XCTAssertTrue(result.stdout.contains(expected), "\(args): \(result.stdout)")
        XCTAssertFalse(result.stdout.contains("via \n"), result.stdout)
      }
    }

    /// `--json` prints the raw reply array unchanged from 1.0: the same keys, decodable by the
    /// 1.0 `PingResult` decoder, with no derived fields added.
    func testPingJSONKeepsOnePointZeroShape() throws {
      let body = try fixture(named: "ping-captured-disco-direct", type: "json")
      let result = try runPing(["100.64.0.2", "--json"], replying: body)
      let array = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
      XCTAssertEqual(array.count, 1)
      XCTAssertEqual(
        Set(array[0].keys),
        [
          "IP", "NodeIP", "NodeName", "Err", "LatencySeconds", "Endpoint", "PeerRelay",
          "DERPRegionID", "DERPRegionCode",
        ])
      let decoded = try JSONDecoder().decode([PingResult].self, from: Data(result.stdout.utf8))
      XCTAssertEqual(decoded, [try JSONDecoder().decode(PingResult.self, from: body)])
    }
  }
#endif
