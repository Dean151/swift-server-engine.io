// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-server-engine.io",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "EngineIO", targets: ["EngineIO"]),
        .executable(name: "EngineIOTestApp", targets: ["EngineIOTestApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.2.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-compression.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.1.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "EngineIO", dependencies: [
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdCompression", package: "hummingbird-compression"),
            .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            .product(name: "HummingbirdWSCompression", package: "hummingbird-websocket"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        ]),
        .testTarget(name: "EngineIOTests", dependencies: [
            "EngineIO",
            .product(name: "HummingbirdTesting", package: "hummingbird"),
            .product(name: "HummingbirdWSCompression", package: "hummingbird-websocket"),
            .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
        ]),
        .executableTarget(name: "EngineIOTestApp", dependencies: ["EngineIO"], path: "Demo/EngineIO"),
    ],
    swiftLanguageModes: [.v6]
)
