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
        ),
        .library(
            name: "TailscaleClientMocks",
            targets: ["TailscaleClientMocks"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "TailscaleClient"
        ),
        .target(
            name: "TailscaleClientMocks",
            dependencies: ["TailscaleClient"]
        ),
        .executableTarget(
            name: "tailscale-swift",
            dependencies: [
                "TailscaleClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "TailscaleClientTests",
            dependencies: ["TailscaleClient", "TailscaleClientMocks"],
            resources: [
                .process("Fixtures")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
