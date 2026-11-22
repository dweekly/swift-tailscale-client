// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import CoreGraphics

/// Every size the window uses, in points, in one place.
public enum Layout {
  /// The window's size when it first opens. Wide enough for the sidebar and a detail pane
  /// whose longest line (the mode explanation) fits without wrapping at the default text
  /// size; tall enough for a full result without scrolling.
  public static let defaultWindowSize = CGSize(width: 860, height: 580)
  /// The smallest size the window can be resized to.
  public static let minimumWindowSize = CGSize(width: 680, height: 520)
  /// Sidebar width range. The ideal fits "example-offline" with its OS and address.
  static let sidebarWidth = (minimum: 200.0, ideal: 230.0, maximum: 320.0)
  /// Margin around the detail pane's sections.
  static let detailPadding = 20.0
  /// Vertical space between groups in the detail pane.
  static let sectionSpacing = 16.0
  /// Space between a label and its value in the result grid.
  static let gridColumnSpacing = 16.0
  /// Space between rows of the result grid.
  static let gridRowSpacing = 6.0
  /// Inner padding of the small capsule that states the result's verdict.
  static let badgePadding = (horizontal: 8.0, vertical: 3.0)
  /// Space between a title and the secondary line under it.
  static let lineSpacing = 2.0
  /// How strongly the verdict capsule is tinted: a light fill, a firmer outline.
  static let badgeFillOpacity = 0.15
  static let badgeStrokeOpacity = 0.5
  /// Inner padding of the boxes in the detail pane.
  static let boxPadding = 12.0
}
