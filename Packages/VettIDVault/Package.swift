// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDVault",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDVault", targets: ["VettIDVault"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDRelay"),
        .package(path: "../VettIDAltChan"),
        // TEST ONLY: the fake HTTP server of the tests.
        .package(path: "../VettIDTesting"),
    ],
    targets: [
        .target(name: "VettIDVault", dependencies: ["VettIDCrypto", "VettIDRelay", "VettIDAltChan"]),
        .testTarget(
            name: "VettIDVaultTests",
            dependencies: ["VettIDVault", "VettIDCrypto", "VettIDRelay", "VettIDAltChan", "VettIDTesting"]
        ),
    ]
)
