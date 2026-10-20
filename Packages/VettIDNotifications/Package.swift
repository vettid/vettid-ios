// swift-tools-version: 6.0
import PackageDescription

// Notifications (vettid-android `feature/notifications`): the vault's feed with the bell's count, the Archived view and
// the detail sheet (IOS-PLAN §8 I2.3; ANDROID-PLAN §4 Notifications). The items' titles are VettIDData's (IOS-PLAN §4.1).
let package = Package(
    name: "VettIDNotifications",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDNotifications", targets: ["VettIDNotifications", "VettIDNotificationsUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDVault"),
        .package(path: "../VettIDUI"),
    ],
    targets: [
        // The view model and its state: no UI, so `swift test` runs its tests on macOS.
        .target(
            name: "VettIDNotifications",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
            ]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDNotificationsUI",
            dependencies: [
                "VettIDNotifications",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDNotificationsTests",
            dependencies: [
                "VettIDNotifications",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
            ]
        ),
        .testTarget(
            name: "VettIDNotificationsUITests",
            dependencies: [
                "VettIDNotifications",
                "VettIDNotificationsUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
