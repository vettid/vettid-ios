// swift-tools-version: 6.0
import PackageDescription

// Calls, part 2 (vettid-android `core/calls`): the call state machine and the vault signalling, with no media stack and no
// UI (IOS-PLAN §8; CALLS-PLAN; VAULT-MESSAGING §10.10). The media engine is a protocol here: its WebRTC implementation is
// VettIDCallsWebRTC, which the app links with this package in every configuration.
let package = Package(
    name: "VettIDCalls",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDCalls", targets: ["VettIDCalls"]),
        // The call screens and the window that presents them (iOS only; empty on macOS).
        .library(name: "VettIDCallsUI", targets: ["VettIDCallsUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDVault"),
        // AccountNames.isolateOrNull: a name with bidi controls cannot reorder the microphone sentence.
        .package(path: "../VettIDData"),
        .package(path: "../VettIDUI"),
    ],
    targets: [
        .target(
            name: "VettIDCalls",
            dependencies: [
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDData", package: "VettIDData"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        // The call screens, the microphone dialogs and the window over the app (iOS only: VettIDUI is UIKit-based).
        .target(
            name: "VettIDCallsUI",
            dependencies: [
                "VettIDCalls",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "VettIDCallsUITests",
            dependencies: [
                "VettIDCalls",
                "VettIDCallsUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "VettIDCallsTests",
            dependencies: [
                "VettIDCalls",
                // TEST ONLY: a real vault manager over the fake vault service (the hang-up before a lock).
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDData", package: "VettIDData"),
            ]
        ),
    ]
)
