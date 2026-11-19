// swift-tools-version: 6.0
import PackageDescription

// What the app shares with its extensions: the links they open it with now, the snapshot they
// read later. GlanceModel imports Foundation only, so it tests on macOS and never pulls the
// protocol layer's sockets into an extension.
let package = Package(
    name: "RexGlance",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v15)],
    products: [
        .library(name: "GlanceModel", targets: ["GlanceModel"]),
    ],
    targets: [
        .target(name: "GlanceModel"),
        .testTarget(name: "GlanceModelTests", dependencies: ["GlanceModel"]),
    ]
)
