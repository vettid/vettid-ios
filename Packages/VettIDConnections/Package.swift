// swift-tools-version: 6.0
import PackageDescription

// Connections (vettid-android `feature/connections`): inviting with a QR code or a link, scanning or pasting an
// invitation, the safety code and both approvals (IOS-PLAN §8 I2.1); the Connections list and detail follow.
let package = Package(
    name: "VettIDConnections",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDConnections", targets: ["VettIDConnections", "VettIDConnectionsUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDUI"),
        // TEST ONLY: real invitation payloads (InviteQr) in the tests.
        .package(path: "../VettIDCrypto"),
    ],
    targets: [
        // The view models and their state: no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDConnections",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
            ]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDConnectionsUI",
            dependencies: [
                "VettIDConnections",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDConnectionsTests",
            dependencies: [
                "VettIDConnections",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
            ]
        ),
        .testTarget(
            name: "VettIDConnectionsUITests",
            dependencies: [
                "VettIDConnections",
                "VettIDConnectionsUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
