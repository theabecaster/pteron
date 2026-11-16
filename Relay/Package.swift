// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RexPushRelay",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "rex-push-relay", targets: ["rex-push-relay"]),
    ],
    targets: [
        .target(name: "RelayCore"),
        .executableTarget(name: "rex-push-relay", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
    ],
    swiftLanguageModes: [.v5]
)
