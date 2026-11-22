// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import AppKit
import PeerDiagnosticsCore
import SwiftUI

/// The windowed app: one window, one model.
///
/// A plain SwiftPM executable has no app bundle or Info.plist, so macOS would treat it as
/// a background tool. The delegate makes it a regular app (Dock icon, menu bar, window in
/// front) and quits it when its window closes.
public struct PeerDiagnosticsApp: App {
  /// Options read from the command line before `main()` runs, because SwiftUI creates the
  /// app value itself and passes it no arguments.
  @MainActor public static var launchOptions = LaunchOptions()

  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  /// The only model. `@StateObject` keeps this one instance for the life of the app, so
  /// the window can never end up with a second model and a second watch.
  @StateObject private var model = PeerDiagnosticsModel()

  public init() {}

  public var body: some Scene {
    // `Window` (not `WindowGroup`) allows exactly one window, so File > New cannot open a
    // second view of the same model.
    Window("Peer Diagnostics", id: "peer-diagnostics") {
      PeerDiagnosticsView(model: model)
        .frame(
          minWidth: Layout.minimumWindowSize.width, minHeight: Layout.minimumWindowSize.height
        )
        .onAppear(perform: startModel)
        .onDisappear(perform: model.stop)
    }
    .defaultSize(Layout.defaultWindowSize)
  }

  private func startModel() {
    let options = Self.launchOptions
    model.allowMacOSAppStoreDiscovery = options.allowMacOSAppStoreDiscovery
    if model.mode != options.mode {
      model.switchMode(to: options.mode)
    } else {
      model.start()
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
