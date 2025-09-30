// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swift-tailscale-client",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "TailscaleClient",
            targets: ["TailscaleClient"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "TailscaleClient"
        ),
        .testTarget(
            name: "TailscaleClientTests",
            dependencies: ["TailscaleClient"],
            resources: [
                .process("Fixtures")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
