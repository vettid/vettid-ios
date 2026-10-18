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
    ],
    targets: [
        .target(
            name: "VettIDData",
            dependencies: ["VettIDCrypto", "VettIDAltChan", "VettIDVault"],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .target(name: "VettIDDataTesting", dependencies: ["VettIDData", "VettIDAltChan"]),
        .testTarget(name: "VettIDDataTests", dependencies: ["VettIDData", "VettIDDataTesting", "VettIDAltChan", "VettIDVault"]),
    ]
)
