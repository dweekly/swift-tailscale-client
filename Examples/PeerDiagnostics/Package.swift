// swift-tools-version: 6.1
import PackageDescription

// Peer Diagnostics: shows which peers the local Tailscale installation knows
// about and how a ping reached the one you select. All state and logic live in
// PeerDiagnosticsCore so they can be tested without a daemon.
//
// This package depends on the library via a path so CI builds it against the
// code under review. To use it as a template, replace the path dependency with
// .package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: <current release>)
let package = Package(
  name: "PeerDiagnostics",
  platforms: [
    .macOS(.v13)
  ],
  dependencies: [
    .package(name: "swift-tailscale-client", path: "../..")
  ],
  targets: [
    .target(
      name: "PeerDiagnosticsCore",
      dependencies: [
        .product(name: "TailscaleClient", package: "swift-tailscale-client")
      ]
    ),
    .executableTarget(
      name: "PeerDiagnostics",
      dependencies: ["PeerDiagnosticsCore"]
    ),
    .testTarget(
      name: "PeerDiagnosticsCoreTests",
      dependencies: [
        "PeerDiagnosticsCore",
        .product(name: "TailscaleClient", package: "swift-tailscale-client"),
        .product(name: "TailscaleClientMocks", package: "swift-tailscale-client"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
