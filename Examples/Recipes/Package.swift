// swift-tools-version: 6.1
import PackageDescription

// Compiled recipe code: every Swift snippet in the DocC "Recipes" articles is
// an excerpt of a file in this package (Scripts/check-recipe-snippets.py
// enforces it), so the documentation cannot drift from code that compiles.
// Copy any file out and replace the path dependency with
// .package(url: "https://github.com/dweekly/swift-tailscale-client.git", from: "0.11.0")
let package = Package(
    name: "Recipes",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "Recipes",
            dependencies: [
                .product(name: "TailscaleClient", package: "swift-tailscale-client")
            ]
        ),
        .testTarget(
            name: "RecipesTests",
            dependencies: [
                "Recipes",
                .product(name: "TailscaleClient", package: "swift-tailscale-client"),
                .product(name: "TailscaleClientMocks", package: "swift-tailscale-client"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
