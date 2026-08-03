// SPDX-License-Identifier: MIT
// Recipe: Build a Tailscale menu-bar status app (macOS).
// Docs: Sources/TailscaleClient/TailscaleClient.docc/RecipeMenuBar.md

#if os(macOS) && canImport(SwiftUI)
  import AppKit
  import SwiftUI
  import TailscaleClient

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
          stateLabel = status.backendState?.rawValue ?? "Unknown"
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
#endif
