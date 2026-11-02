// swift-tools-version: 6.0
import PackageDescription

// Votes (vettid-android `feature/votes`): the Votes list, a vote with its cast, proof and release, and "Is this your
// vote?" (IOS-PLAN §4.16, §8; ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes").
let package = Package(
    name: "VettIDVotes",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDVotes", targets: ["VettIDVotes", "VettIDVotesUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDUI"),
    ],
    targets: [
        // The view models, their state and every text of the Votes screens: no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDVotes",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDVotesUI",
            dependencies: [
                "VettIDVotes",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "VettIDVotesTests",
            dependencies: [
                "VettIDVotes",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
            ]
        ),
        .testTarget(
            name: "VettIDVotesUITests",
            dependencies: [
                "VettIDVotes",
                "VettIDVotesUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
