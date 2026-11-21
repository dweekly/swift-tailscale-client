// SPDX-License-Identifier: MIT
// Recipe: Explain how a ping reached a peer.
// Docs: the PingPath symbol documentation (Sources/TailscaleClient/Models/PingResult.swift)

import TailscaleClient

/// Pings `ip` once and says how that one reply travelled.
public func describePing(ip: String) async throws -> String {
  let client = TailscaleClient()
  let result = try await client.ping(ip: ip)
  return describe(result)
}

/// Describes one ping reply. A single DERP reply is not the peer's settled path: the first
/// disco ping to an idle peer often travels over DERP while a direct path forms.
public func describe(_ result: PingResult) -> String {
  switch result.path {
  case .direct(let endpoint)?: return "direct via \(endpoint)"
  case .peerRelay(let endpoint)?: return "peer relay via \(endpoint)"
  case .derp(_, let code)?: return "DERP via \(code ?? "unknown region")"
  case .unknown?: return "reply without a path"
  case nil: return "failed: \(result.error ?? "")"
  }
}
