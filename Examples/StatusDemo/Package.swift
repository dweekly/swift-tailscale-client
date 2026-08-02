// swift-tools-version: 6.1
import PackageDescription

// Standalone example consuming swift-tailscale-client via a path dependency.
// Copy this package out and replace the path with
// .package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.6.0")
let package = Package(
    name: "StatusDemo",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "StatusDemo",
            dependencies: [
                .product(name: "TailscaleClient", package: "swift-tailscale-client")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
