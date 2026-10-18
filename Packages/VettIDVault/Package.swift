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
        .package(path: "../VettIDAttestation"),
        .package(path: "../VettIDRelay"),
        .package(path: "../VettIDAltChan"),
        // TEST ONLY: the fake HTTP server of the tests.
        .package(path: "../VettIDTesting"),
    ],
    targets: [
        .target(name: "VettIDVault", dependencies: ["VettIDCrypto", "VettIDAttestation", "VettIDRelay", "VettIDAltChan"]),
        .testTarget(
            name: "VettIDVaultTests",
            dependencies: [
                "VettIDVault", "VettIDCrypto", "VettIDAttestation", "VettIDRelay", "VettIDAltChan", "VettIDTesting",
                // TEST ONLY: the TEST iOS attester and the dev stack's helpers (the dev stack test).
                .product(name: "VettIDAltChanTesting", package: "VettIDAltChan"),
            ]
        ),
    ]
)
