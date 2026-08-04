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
