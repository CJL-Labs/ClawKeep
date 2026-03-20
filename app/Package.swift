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
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "2.2.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.36.0")
    ],
    targets: [
        .executableTarget(
            name: "ClawKeep",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "ClawKeep"
        )
    ]
)
