// swift-tools-version: 6.0
import PackageDescription

// What the app shares with its extensions. GlanceModel: the links that open the app and the
// snapshot of the agents that the app writes and the widgets read. It imports Foundation only,
// so it tests on macOS and never pulls the protocol layer's sockets into an extension.
// GlanceUI: the colors, the ring and the type the widgets draw with. SwiftUI only: nothing of
// WidgetKit or UIKit, so a watch target can use it as it is.
let package = Package(
    name: "RexGlance",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v15)],
    products: [
        .library(name: "GlanceModel", targets: ["GlanceModel"]),
        .library(name: "GlanceUI", targets: ["GlanceUI"]),
    ],
    targets: [
        .target(name: "GlanceModel"),
        .target(name: "GlanceUI", dependencies: ["GlanceModel"]),
        .testTarget(name: "GlanceModelTests", dependencies: ["GlanceModel"], resources: [.copy("Fixtures")]),
        .testTarget(name: "GlanceUITests", dependencies: ["GlanceUI"]),
    ]
)
