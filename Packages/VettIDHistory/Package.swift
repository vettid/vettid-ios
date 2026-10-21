// swift-tools-version: 6.0
import PackageDescription

// History (vettid-android `feature/history`): the member's audit log with its search, filters and paging, an entry's
// detail, and the export through "Save to Files" (IOS-PLAN §8 I2.3; ANDROID-PLAN §4 History; IOS-PLAN §4.1 titles).
let package = Package(
    name: "VettIDHistory",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDHistory", targets: ["VettIDHistory", "VettIDHistoryUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDVault"),
        .package(path: "../VettIDUI"),
    ],
    targets: [
        // The view models, their state and every text of History (the titles a search and an export use): no UI, so
        // `swift test` runs their tests on macOS.
        .target(
            name: "VettIDHistory",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDHistoryUI",
            dependencies: [
                "VettIDHistory",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "VettIDHistoryTests",
            dependencies: [
                "VettIDHistory",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
            ]
        ),
        .testTarget(
            name: "VettIDHistoryUITests",
            dependencies: [
                "VettIDHistory",
                "VettIDHistoryUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
