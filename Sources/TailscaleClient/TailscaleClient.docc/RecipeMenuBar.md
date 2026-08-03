# Recipe: Build a Tailscale Menu-Bar Status App

A macOS `MenuBarExtra` that shows live Tailscale state — seeded from one
`status()` call, kept fresh by the IPN bus, never polling.

> Important: `swift-tailscale-client` is a personal project by David E. Weekly and is **not** affiliated with or endorsed by Tailscale Inc.

Every snippet below is compiled by CI from
[`Examples/Recipes`](https://github.com/dweekly/swift-tailscale-client/tree/main/Examples/Recipes) —
copy that package for a running start.

## The observable model

Seed the UI once, then follow the bus with `reconnect: .default` so the app
survives daemon restarts:

```swift
  @MainActor
  final class TailscaleStatusModel: ObservableObject {
    @Published var stateLabel = "…"
    @Published var hostName = ""
    @Published var online = false

    private var watcher: Task<Void, Never>?
    private let client = TailscaleClient()

    func start() {
      watcher = Task {
        // Seed the UI, then follow the IPN bus instead of polling.
        if let status = try? await client.status() {
          hostName = status.selfNode?.hostName ?? "?"
          stateLabel = status.backendState ?? "Unknown"
        }
        do {
          let stream = try await client.watchIPNBus(
            options: [.initialState], reconnect: .default)
          for try await notify in stream {
            if let state = notify.state {
              stateLabel = "\(state)"
              online = state == .running
            }
          }
        } catch {
          stateLabel = "Disconnected"
        }
      }
    }

    func stop() {
      watcher?.cancel()
    }
  }
```

## The menu-bar scene

```swift
  struct TailscaleMenuBarApp: App {  // add @main in your app target
    @StateObject private var model = TailscaleStatusModel()

    var body: some Scene {
      MenuBarExtra("Tailscale", systemImage: online ? "checkmark.shield" : "shield") {
        Text("\(model.hostName): \(model.stateLabel)")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
      }
      .menuBarExtraStyle(.menu)
    }

    private var online: Bool { model.online }
  }
```

## Distribution notes

- Sandboxed apps need entitlements that allow reaching the tailscaled unix
  socket; test discovery inside the sandbox early.
- If your users run the **App Store** Tailscale app, you must opt in to
  Group-Container discovery (and its TCC popup) — see <doc:DiscoveryAndPermissions>.

## See also

- <doc:RecipeMonitoring> for the full event-handling pattern.
- <doc:Streaming> for stream semantics (skip-and-report, reconnect backoff).
