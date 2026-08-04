import AppKit
import SwiftUI
import TailscaleClient

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
