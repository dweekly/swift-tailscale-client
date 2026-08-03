# Recipe: Test a Tailscale Integration Using Mocks

Deterministic tests with the shipped `TailscaleClientMocks` product — no
daemon, no network, no flakes.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

Every snippet below runs in CI as a test in
[`Examples/Recipes`](https://github.com/dweekly/swift-tailscale-client/tree/main/Examples/Recipes).
Add the product to your test target:

```
.product(name: "TailscaleClientMocks", package: "swift-tailscale-client")
```

## Answer requests from fixtures

```swift
  func testStatusAgainstAFixture() async throws {
    // MockTransport answers every request from your closure — no daemon.
    let fixture = Data(#"{"BackendState": "Running", "TailscaleIPs": ["100.64.0.1"]}"#.utf8)
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.path, "/localapi/v0/status")
      return TailscaleResponse(statusCode: 200, data: fixture)
    }
    let client = TailscaleClient(
      configuration: TailscaleClientConfiguration(
        endpoint: .url(URL(string: "http://mock.local")!),
        authToken: nil,
        transport: transport))

    let status = try await client.status()
    XCTAssertEqual(status.backendState, .running)
  }
```

## Record and assert on writes

```swift
    var change = MaskedPrefs()
    change.shieldsUp = true
    _ = try await client.editPrefs(change)

    let requests = await recorder.requests
    XCTAssertEqual(requests.first?.method, "PATCH")
    XCTAssertEqual(requests.first?.path, "/localapi/v0/prefs")
```

## Script the IPN bus

```swift
    let transport = MockTransport.scriptedStream([
      .jsonLine(#"{"State": 6}"#),
      .jsonLine(#"{"State": 4}"#),
    ])
```

`scriptedStreams([[…], […]])` scripts successive connections for reconnect
scenarios, and `.delay(_:)` inserts pauses.

## See also

- <doc:ErrorHandling> — asserting on typed `TailscaleClientError` cases.
