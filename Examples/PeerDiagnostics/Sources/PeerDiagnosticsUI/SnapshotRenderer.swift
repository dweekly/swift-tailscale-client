// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import AppKit
import PeerDiagnosticsCore
import SwiftUI

/// Draws the window's content to a PNG without showing anything on screen.
///
/// The view is hosted in an `NSHostingView` inside a window that is never ordered on
/// screen, so lists and split views lay out exactly as they do in the app, then drawn into
/// a bitmap with `cacheDisplay(in:to:)`. (SwiftUI's `ImageRenderer` does not draw
/// AppKit-backed views such as `List`.) The picture is the window's content area: the
/// title bar and its buttons belong to the system and are not part of it.
@MainActor
public enum SnapshotRenderer {
  /// The picture's size in points: the window's default size.
  public static let size = Layout.defaultWindowSize
  /// Pixels per point, as on a Retina display, so the picture is sharp in documentation.
  public static let scale = 2
  /// How long AppKit and SwiftUI get to finish layout before the picture is taken. Layout
  /// completes in a few run-loop turns; this leaves a wide margin.
  static let settleTime: TimeInterval = 0.5

  /// Why rendering failed.
  public enum RenderError: Error {
    case bitmapUnavailable
    case encodingFailed
  }

  /// The PNG bytes of `view` drawn at ``size`` and ``scale`` in `appearance`.
  public static func png(of view: some View, appearance: LaunchOptions.Appearance) throws -> Data {
    _ = NSApplication.shared  // AppKit drawing needs the shared application to exist.
    let rect = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: rect, styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    let colorScheme: ColorScheme = appearance == .dark ? .dark : .light
    let host = NSHostingView(
      rootView:
        view
        .frame(width: size.width, height: size.height)
        // The window paints this behind its content; an offscreen bitmap starts transparent.
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, colorScheme))
    host.frame = rect
    host.sizingOptions = []
    window.contentView = host

    // Let SwiftUI apply state and lay out the AppKit views it created.
    let deadline = Date().addingTimeInterval(settleTime)
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(settleTime / 10))
    }
    host.layoutSubtreeIfNeeded()

    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)
    else { throw RenderError.bitmapUnavailable }
    bitmap.size = size
    window.appearance?.performAsCurrentDrawingAppearance {
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw RenderError.encodingFailed
    }
    return data
  }

  /// Prepares ``SnapshotScenario`` and renders the same root view the window shows.
  public static func renderScenario(appearance: LaunchOptions.Appearance) async throws -> Data {
    let model = try await SnapshotScenario.prepareModel()
    defer { model.stop() }
    let view = PeerDiagnosticsView(model: model)
      .environment(\.timeZone, SnapshotScenario.timeZone)
    return try png(of: view, appearance: appearance)
  }
}
