// SPDX-License-Identifier: MIT
// Recipe: Select or disable an exit node safely.
// Docs: Sources/TailscaleClient/TailscaleClient.docc/RecipeExitNode.md

import TailscaleClient

/// Lists peers that offer themselves as exit nodes, using the daemon's own
/// suggestion to mark the best candidate.
public func exitNodeCandidates() async throws -> [(id: String, name: String, suggested: Bool)] {
  let client = TailscaleClient()
  let status = try await client.status(query: StatusQuery(includePeers: true))
  let suggestion = try? await client.suggestExitNode()

  return status.peers.values
    .filter { $0.exitNodeOption == true }
    .map { peer in
      (id: peer.id, name: peer.hostName, suggested: peer.id == suggestion?.id)
    }
    .sorted { $0.name < $1.name }
}

/// Routes traffic through the given exit node. Uses a masked write so ONLY
/// the exit-node selection changes — every other preference is untouched.
public func selectExitNode(stableID: String) async throws {
  let client = TailscaleClient()
  var change = MaskedPrefs()
  change.exitNodeID = stableID
  _ = try await client.editPrefs(change)
}

/// Stops using the exit node but REMEMBERS the selection, so the user can
/// re-enable it with one call — prefer this over clearing exitNodeID.
public func pauseExitNode() async throws {
  let client = TailscaleClient()
  _ = try await client.setUseExitNode(enabled: false)
}

/// Re-enables the remembered exit node.
public func resumeExitNode() async throws {
  let client = TailscaleClient()
  _ = try await client.setUseExitNode(enabled: true)
}
