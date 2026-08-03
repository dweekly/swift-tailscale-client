// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

/// Regression tests for issue draft 01: no LocalAPI authentication-token
/// material — or any meaningful substring of it — may reach a diagnostic
/// surface. Each test injects a recognizable secret and captures every line
/// the supported surfaces can emit.
final class SecretRedactionTests: XCTestCase {

  private let secret = "SECRETTOKEN0123456789abcdef"

  /// Every ≥4-char substring of the secret counts as a leak; checking the
  /// full value and a few windows keeps the assertion honest and fast.
  private func assertFree(of secret: String, _ text: String, _ label: String) {
    XCTAssertFalse(text.contains(secret), "\(label) leaked the full secret: \(text)")
    let head = String(secret.prefix(8))
    XCTAssertFalse(text.contains(head), "\(label) leaked a secret prefix: \(text)")
    let mid = String(secret.dropFirst(8).prefix(8))
    XCTAssertFalse(text.contains(mid), "\(label) leaked a secret substring: \(text)")
  }

  func testProofPathRedactionMasksTheTokenComponent() {
    let path = "/tmp/containers/sameuserproof-53422-\(secret)"
    let redacted = DiscoveryLog.redactedProofPath(path)
    assertFree(of: secret, redacted, "redactedProofPath")
    XCTAssertTrue(redacted.contains("53422"), "The port is non-secret provenance: \(redacted)")
    XCTAssertTrue(redacted.contains("sameuserproof-"), "Keep the file kind: \(redacted)")
  }

  func testProofPathRedactionPassesThroughOrdinaryPaths() {
    XCTAssertEqual(
      DiscoveryLog.redactedProofPath("/var/run/tailscaled.socket"),
      "/var/run/tailscaled.socket")
  }

  func testDiscoveryResultDescriptionRedactsAuthToken() {
    let result = LocalAPIDiscovery.Result(
      endpoint: .loopback(host: "127.0.0.1", port: 4242),
      authToken: secret,
      capabilityVersion: 1)
    assertFree(of: secret, "\(result)", "Result.description")
    assertFree(of: secret, String(reflecting: result), "Result.debugDescription")
    XCTAssertTrue("\(result)".contains("<redacted>"))
  }

  func testConfigurationDescriptionRedactsAuthToken() {
    let configuration = TailscaleClientConfiguration(
      endpoint: .loopback(host: "127.0.0.1", port: 4242),
      authToken: secret)
    assertFree(of: secret, "\(configuration)", "Configuration.description")
    assertFree(of: secret, String(reflecting: configuration), "Configuration.debugDescription")
    XCTAssertTrue("\(configuration)".contains("<redacted>"))
  }

  func testCertPairDescriptionRedactsPrivateKey() {
    let key = "-----BEGIN PRIVATE KEY-----\n\(secret)\n-----END PRIVATE KEY-----\n"
    let pair = CertPair(certificatePEM: "CERT", privateKeyPEM: key)
    assertFree(of: secret, "\(pair)", "CertPair.description")
    assertFree(of: secret, String(reflecting: pair), "CertPair.debugDescription")
  }

  #if os(macOS)
    func testMacDiscoveryLoggingNeverEmitsTokenMaterial() throws {
      // A real sameuserproof file whose NAME embeds the token — exactly the
      // shape App Store discovery scans for.
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("redaction-\(UUID().uuidString.prefix(8))")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }
      let proof = dir.appendingPathComponent("sameuserproof-53423-\(secret)")
      FileManager.default.createFile(atPath: proof.path, contents: Data())

      let recorder = LogRecorder()
      DiscoveryLog.sink = { line in recorder.append(line) }
      defer { DiscoveryLog.sink = nil }

      setenv("TAILSCALE_SAMEUSER_PATH", proof.path, 1)
      setenv("TAILSCALE_DISCOVERY_DEBUG", "1", 1)
      defer {
        unsetenv("TAILSCALE_SAMEUSER_PATH")
        unsetenv("TAILSCALE_DISCOVERY_DEBUG")
      }

      let result = MacClientInfo().locateSameUserProof()
      XCTAssertEqual(result?.token, secret, "Discovery itself must still return the token")

      let lines = recorder.snapshot()
      XCTAssertFalse(lines.isEmpty, "Discovery must stay diagnosable (some logging expected)")
      for line in lines {
        assertFree(of: secret, line, "discovery log line")
      }
    }
  #endif
}

/// Minimal thread-safe line collector for the log sink.
private final class LogRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []

  func append(_ line: String) {
    lock.lock()
    lines.append(line)
    lock.unlock()
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
}
