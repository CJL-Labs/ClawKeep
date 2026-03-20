// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClawKeep",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ClawKeep", targets: ["ClawKeep"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClawKeep",
            dependencies: [],
            path: "ClawKeep"
        )
    ]
)
