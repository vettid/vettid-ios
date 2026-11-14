// swift-tools-version: 6.0
import PackageDescription

// Calls, part 2 (vettid-android `core/calls`): the call state machine and the vault signalling, with no media stack and no
// UI (IOS-PLAN §8; CALLS-PLAN; VAULT-MESSAGING §10.10). The media engine is a protocol here; its WebRTC implementation is
// a later change.
let package = Package(
    name: "VettIDCalls",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDCalls", targets: ["VettIDCalls"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDVault"),
        // AccountNames.isolateOrNull: a name with bidi controls cannot reorder the microphone sentence.
        .package(path: "../VettIDData"),
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
        .testTarget(
            name: "VettIDCallsTests",
            dependencies: [
                "VettIDCalls",
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDData", package: "VettIDData"),
            ]
        ),
    ]
)
