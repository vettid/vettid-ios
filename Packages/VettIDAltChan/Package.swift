// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDAltChan",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDAltChan", targets: ["VettIDAltChan"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDAttestation"),
        .package(path: "../VettIDRelay"),
        // TEST ONLY: the fake HTTP server of the tests.
        .package(path: "../VettIDTesting"),
    ],
    targets: [
        .target(name: "VettIDAltChan", dependencies: ["VettIDCrypto", "VettIDAttestation", "VettIDRelay"]),
        .testTarget(
            name: "VettIDAltChanTests",
            dependencies: ["VettIDAltChan", "VettIDCrypto", "VettIDAttestation", "VettIDRelay", "VettIDTesting"],
            exclude: ["Resources/SOURCE.md"],
            resources: [.copy("Resources/vectors")]
        ),
    ]
)
