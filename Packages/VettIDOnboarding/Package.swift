// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDOnboarding",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDOnboarding", targets: ["VettIDOnboarding", "VettIDOnboardingUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDAltChan"),
        .package(path: "../VettIDUI"),
        // TEST ONLY: VaultOpError for the vault's weak_password reason in the tests.
        .package(path: "../VettIDVault"),
        // TEST ONLY: InviteQr, to make the transfer codes the new phone scans.
        .package(path: "../VettIDCrypto"),
    ],
    targets: [
        // The view model and its state: no UI, so `swift test` runs its tests on macOS.
        .target(
            name: "VettIDOnboarding",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDAltChan", package: "VettIDAltChan"),
            ]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDOnboardingUI",
            dependencies: [
                "VettIDOnboarding",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDOnboardingTests",
            dependencies: [
                "VettIDOnboarding",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDAltChan", package: "VettIDAltChan"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
            ]
        ),
        .testTarget(
            name: "VettIDOnboardingUITests",
            dependencies: [
                "VettIDOnboarding",
                "VettIDOnboardingUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
