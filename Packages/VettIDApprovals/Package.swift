// swift-tools-version: 6.0
import PackageDescription

// Approvals (vettid-android `feature/approvals`): everything that waits for the member's decision, connection requests
// included, a connection's asks batched, paused connections, and one approval's decision screen (IOS-PLAN §8 I2.3).
let package = Package(
    name: "VettIDApprovals",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDApprovals", targets: ["VettIDApprovals", "VettIDApprovalsUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDUI"),
        // TEST ONLY: critical-use payloads and their hashes in the tests.
        .package(path: "../VettIDCrypto"),
    ],
    targets: [
        // The view models and their state: no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDApprovals",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
            ]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDApprovalsUI",
            dependencies: [
                "VettIDApprovals",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDApprovalsTests",
            dependencies: [
                "VettIDApprovals",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
            ]
        ),
        .testTarget(
            name: "VettIDApprovalsUITests",
            dependencies: [
                "VettIDApprovals",
                "VettIDApprovalsUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
