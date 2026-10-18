// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDData",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDData", targets: ["VettIDData"]),
        // TEST ONLY: the repository-level fake for view-model tests, never linked by the app. It lives here, not in
        // VettIDTesting, because VettIDAltChan and VettIDVault use VettIDTesting in their tests: VettIDTesting
        // depending on VettIDData would close a package cycle.
        .library(name: "VettIDDataTesting", targets: ["VettIDDataTesting"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDAltChan"),
        .package(path: "../VettIDVault"),
        .package(path: "../VettIDKeys"),
    ],
    targets: [
        .target(
            name: "VettIDData",
            dependencies: ["VettIDCrypto", "VettIDAltChan", "VettIDVault", .product(name: "VettIDKeys", package: "VettIDKeys")],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .target(name: "VettIDDataTesting", dependencies: ["VettIDData", "VettIDAltChan"]),
        .testTarget(
            name: "VettIDDataTests",
            dependencies: [
                "VettIDData", "VettIDDataTesting", "VettIDAltChan", "VettIDVault",
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
