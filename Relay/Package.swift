// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RexPushRelay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RexConnectHelper", targets: ["RexConnectHelper"]),
        .executable(name: "rex-push-relay", targets: ["rex-push-relay"]),
    ],
    dependencies: [
        // JSON helpers and errors shared with the iOS app.
        .package(path: "../Packages/RexKit"),
    ],
    targets: [
        .target(name: "RelayCore", dependencies: ["RexKit"]),
        // The app ("Rex Connect Helper.app"); package.sh wraps this binary in a signed bundle.
        .executableTarget(name: "RexConnectHelper", dependencies: ["RelayCore", "RexKit"]),
        // Command-line build of the same relay, for development.
        .executableTarget(name: "rex-push-relay", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore", "RexKit"]),
    ],
    swiftLanguageModes: [.v5]
)
