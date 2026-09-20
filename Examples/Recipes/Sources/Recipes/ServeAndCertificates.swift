// SPDX-License-Identifier: MIT
// Recipe: Configure Tailscale Serve and retrieve certificates.
// Docs: Sources/TailscaleClient/TailscaleClient.docc/RecipeServe.md

import Foundation
import TailscaleClient

/// Adds one TCP forward without disturbing anything else the node serves.
/// The snapshot-mutate-write loop retries when another writer (the
/// Tailscale CLI, a GUI) changes the config concurrently.
public func addTCPForward(port: UInt16, to target: String) async throws {
  let client = TailscaleClient()
  for _ in 0..<3 {
    let snapshot = try await client.serveConfigSnapshot()
    var config = snapshot.config
    config.tcp[port] = TCPPortHandler(tcpForward: target)
    do {
      _ = try await client.setServeConfig(config, matching: snapshot)
      return
    } catch TailscaleClientError.preconditionFailed {
      continue  // someone else won the race — rebase on their change and retry
    }
  }
  throw TailscaleClientError.preconditionFailed(
    body: Data(), endpoint: "/localapi/v0/serve-config")
}

/// Removes the forward added above, with the same concurrency discipline.
public func removeTCPForward(port: UInt16) async throws {
  let client = TailscaleClient()
  let snapshot = try await client.serveConfigSnapshot()
  var config = snapshot.config
  config.tcp[port] = nil
  _ = try await client.setServeConfig(config, matching: snapshot)
}

/// Fetches this node's TLS credential for its first cert domain. The first
/// call for a domain may block while the daemon completes ACME issuance,
/// so give the client a generous timeout.
public func fetchCertificate() async throws -> CertPair? {
  var configuration = TailscaleClientConfiguration.default
  configuration.requestTimeout = .seconds(120)
  let client = TailscaleClient(configuration: configuration)

  guard let domain = try await client.certDomains().first else {
    return nil  // HTTPS is not enabled for this tailnet
  }
  return try await client.certPair(domain: domain)
}
