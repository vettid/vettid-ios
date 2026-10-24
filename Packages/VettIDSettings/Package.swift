// swift-tools-version: 6.0
import PackageDescription

// Settings (vettid-android `feature/settings` and `feature/credential`): the Settings screen, Vault status, Attestation,
// the name change, the PIN change, the Credential screen and Help (IOS-PLAN §8 I1.8); the shared profile and the
// camera-only profile photo (I2.5).
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
        // The profile photo (VAULT-MESSAGING §10.8): the shot's pixels and the JPEG of at most 65,536 bytes.
        .package(path: "../VettIDMedia"),
        // The PIN keypad's entry of onboarding (IOS-PLAN §6.5) and its password rule line.
        .package(path: "../VettIDOnboarding"),
        // TEST ONLY: VaultOpError for the vault's weak_password reason in the tests.
        .package(path: "../VettIDVault"),
    ],
    targets: [
        // The view models and their state: no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDSettings",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDKeys", package: "VettIDKeys"),
                .product(name: "VettIDMedia", package: "VettIDMedia"),
            ]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDSettingsUI",
            dependencies: [
                "VettIDSettings",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDKeys", package: "VettIDKeys"),
                .product(name: "VettIDMedia", package: "VettIDMedia"),
                .product(name: "VettIDOnboarding", package: "VettIDOnboarding"),
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
                .product(name: "VettIDMedia", package: "VettIDMedia"),
                .product(name: "VettIDVault", package: "VettIDVault"),
            ]
        ),
        .testTarget(
            name: "VettIDSettingsUITests",
            dependencies: [
                "VettIDSettings",
                "VettIDSettingsUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDMedia", package: "VettIDMedia"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
