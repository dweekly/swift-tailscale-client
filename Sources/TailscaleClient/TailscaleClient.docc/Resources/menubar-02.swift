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
      // Seed the UI once from status().
      if let status = try? await client.status() {
        hostName = status.selfNode?.hostName ?? "?"
        stateLabel = status.backendState?.rawValue ?? "Unknown"
      }
    }
  }

  func stop() {
    watcher?.cancel()
  }
}
