// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RexPushRelay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RexConnectHelper", targets: ["RexConnectHelper"]),
        .executable(name: "rex-push-relay", targets: ["rex-push-relay"]),
    ],
    targets: [
        .target(name: "RelayCore"),
        // The app ("Rex Connect Helper.app"); package.sh wraps this binary in a signed bundle.
        .executableTarget(name: "RexConnectHelper", dependencies: ["RelayCore"]),
        // Command-line build of the same relay, for development.
        .executableTarget(name: "rex-push-relay", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
    ],
    swiftLanguageModes: [.v5]
)
