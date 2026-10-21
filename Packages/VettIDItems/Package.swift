// swift-tools-version: 6.0
import PackageDescription

// The Vault (vettid-android `feature/items`): the member's items and their tags (IOS-PLAN §8 I3.1; ANDROID-PLAN §4
// Vault; VAULT-ITEMS). I3.1b brings the tags' screen and the colours of the tags; the item screens follow.
let package = Package(
    name: "VettIDItems",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDItems", targets: ["VettIDItems", "VettIDItemsUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDVault"),
        .package(path: "../VettIDUI"),
    ],
    targets: [
        // The view models, their state and every text of the Vault (vettid-android's `strings.xml` and
        // `strings_sharing.xml`): no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDItems",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDItemsUI",
            dependencies: [
                "VettIDItems",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "VettIDItemsTests",
            dependencies: [
                "VettIDItems",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
            ]
        ),
        .testTarget(
            name: "VettIDItemsUITests",
            dependencies: [
                "VettIDItems",
                "VettIDItemsUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
