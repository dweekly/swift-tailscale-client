import SwiftUI
import TailscaleClient

@MainActor
final class TailscaleStatusModel: ObservableObject {
  @Published var stateLabel = "…"
  @Published var hostName = ""
  @Published var online = false

  private var watcher: Task<Void, Never>?
  private let client = TailscaleClient()
}
