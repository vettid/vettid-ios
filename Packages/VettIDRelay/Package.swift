// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDRelay",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDRelay", targets: ["VettIDRelay"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        // TEST ONLY: the fake HTTP server of the tests.
        .package(path: "../VettIDTesting"),
    ],
    targets: [
        .target(name: "VettIDRelay", dependencies: ["VettIDCrypto"]),
        .testTarget(name: "VettIDRelayTests", dependencies: ["VettIDRelay", "VettIDCrypto", "VettIDTesting"]),
    ]
)
