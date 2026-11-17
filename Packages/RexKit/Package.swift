// swift-tools-version: 6.0
import PackageDescription

// Rex's protocol layer: the control connection, models and the terminal data stream.
// Foundation and CoreGraphics only, so it builds and tests on macOS (`swift test`) and is shared
// by the iOS app. The push helper in Relay/ is Rust.
let package = Package(
    name: "RexKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "RexKit", targets: ["RexKit"])],
    targets: [
        .target(name: "RexKit"),
        // Fixtures: recorded Rex data streams (scripts/ghostty-tools/capture.mjs) and their nonces.
        .testTarget(name: "RexKitTests", dependencies: ["RexKit"], resources: [.copy("Fixtures")]),
    ]
)
