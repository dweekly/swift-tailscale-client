# Recipe: Select or Disable an Exit Node Safely

List candidates, apply the choice with a masked write, and pause instead of
forgetting the selection.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

Every snippet below is compiled by CI from
[`Examples/Recipes`](https://github.com/dweekly/swift-tailscale-client/tree/main/Examples/Recipes).

## List the candidates

```swift
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
```

## Apply the choice — masked, not wholesale

```swift
/// Routes traffic through the given exit node. Uses a masked write so ONLY
/// the exit-node selection changes — every other preference is untouched.
public func selectExitNode(stableID: String) async throws {
  let client = TailscaleClient()
  var change = MaskedPrefs()
  change.exitNodeID = stableID
  _ = try await client.editPrefs(change)
}
```

## Pause, don't forget

```swift
/// Stops using the exit node but REMEMBERS the selection, so the user can
/// re-enable it with one call — prefer this over clearing exitNodeID.
public func pauseExitNode() async throws {
  let client = TailscaleClient()
  _ = try await client.setUseExitNode(enabled: false)
}
```

Clearing `exitNodeID` throws the user's choice away; `setUseExitNode` is the
`tailscale set --exit-node=` on/off toggle and round-trips cleanly.

## See also

- <doc:WritingSafely> — the full masked-write model and validation via `checkPrefs(_:)`.
