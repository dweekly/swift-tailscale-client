// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import AppKit
import PeerDiagnosticsCore
import PeerDiagnosticsUI
import XCTest

@MainActor
final class SnapshotTests: XCTestCase {
  func testSnapshotRendersAPNGOfTheExpectedPixelSize() async throws {
    let png = try await SnapshotRenderer.renderScenario(appearance: .light)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
    XCTAssertEqual(bitmap.pixelsWide, Int(SnapshotRenderer.size.width) * SnapshotRenderer.scale)
    XCTAssertEqual(bitmap.pixelsHigh, Int(SnapshotRenderer.size.height) * SnapshotRenderer.scale)
    XCTAssertTrue(hasManyColors(bitmap), "the snapshot looks blank")
  }
}

/// A blank or single-color render would pass a size check; a drawn window has text.
@MainActor
func hasManyColors(_ bitmap: NSBitmapImageRep) -> Bool {
  var seen = Set<UInt32>()
  let step = 7
  for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
    for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
      let packed =
        UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
        | UInt32(color.blueComponent * 255)
      seen.insert(packed)
      if seen.count > 16 { return true }
    }
  }
  return false
}
