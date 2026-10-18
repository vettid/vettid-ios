// swift-tools-version: 6.0
import PackageDescription

// Settings (vettid-android `feature/settings`): the Settings screen, Vault status and Attestation (IOS-PLAN §8 I1.8).
let package = Package(
    name: "VettIDSettings",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDSettings", targets: ["VettIDSettings", "VettIDSettingsUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDKeys"),
        .package(path: "../VettIDUI"),
    ],
    targets: [
        // The view models and their state: no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDSettings",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDKeys", package: "VettIDKeys"),
            ]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDSettingsUI",
            dependencies: [
                "VettIDSettings",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDKeys", package: "VettIDKeys"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDSettingsTests",
            dependencies: [
                "VettIDSettings",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDKeys", package: "VettIDKeys"),
            ]
        ),
        .testTarget(
            name: "VettIDSettingsUITests",
            dependencies: [
                "VettIDSettings",
                "VettIDSettingsUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
