// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDData",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDData", targets: ["VettIDData"]),
        // TEST ONLY: the repository-level fake for view-model tests and the fake vault service the vault manager's
        // end-to-end tests run against, never linked by the app. It lives here, not in VettIDTesting, because
        // VettIDAltChan and VettIDVault use VettIDTesting in their tests: VettIDTesting depending on VettIDData would
        // close a package cycle.
        .library(name: "VettIDDataTesting", targets: ["VettIDDataTesting"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDAttestation"),
        .package(path: "../VettIDRelay"),
        .package(path: "../VettIDAltChan"),
        .package(path: "../VettIDVault"),
        .package(path: "../VettIDKeys"),
        // TEST ONLY: the fake HTTP server of VettIDDataTesting's fake vault service.
        .package(path: "../VettIDTesting"),
    ],
    targets: [
        .target(
            name: "VettIDData",
            dependencies: [
                "VettIDCrypto", "VettIDAttestation", "VettIDRelay", "VettIDAltChan", "VettIDVault",
                .product(name: "VettIDKeys", package: "VettIDKeys"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .target(
            name: "VettIDDataTesting",
            dependencies: [
                "VettIDData", "VettIDCrypto", "VettIDAttestation", "VettIDRelay", "VettIDAltChan", "VettIDVault", "VettIDTesting",
                .product(name: "VettIDKeys", package: "VettIDKeys"),
                .product(name: "VettIDKeysTesting", package: "VettIDKeys"),
            ]
        ),
        .testTarget(
            name: "VettIDDataTests",
            dependencies: [
                "VettIDData", "VettIDDataTesting", "VettIDCrypto", "VettIDAttestation", "VettIDRelay", "VettIDAltChan",
                "VettIDVault", "VettIDTesting",
                .product(name: "VettIDKeys", package: "VettIDKeys"),
                // TEST ONLY: the software phone key.
                .product(name: "VettIDKeysTesting", package: "VettIDKeys"),
            ],
            // The Go reference's values of the iPhone's unlock secret (Resources/reference/SOURCE.md), read from the
            // source tree like Localizable.xcstrings: a resource bundle here would shadow VettIDData's `Bundle.module`.
            exclude: ["Resources"]
        ),
    ]
)
