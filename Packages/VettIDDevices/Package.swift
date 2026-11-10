// swift-tools-version: 6.0
import PackageDescription

// Devices & agents (vettid-android `feature/devices`): the list of this phone, agents and desktops, and a device's page with
// End access and Remove (ANDROID-PLAN 0.1.53 AA1 §4 "Devices & agents"; VAULT-MESSAGING §10.3).
let package = Package(
    name: "VettIDDevices",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDDevices", targets: ["VettIDDevices", "VettIDDevicesUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDUI"),
    ],
    targets: [
        // The view models, their state and every text of the Devices & agents screens: no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDDevices",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDDevicesUI",
            dependencies: [
                "VettIDDevices",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "VettIDDevicesTests",
            dependencies: [
                "VettIDDevices",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
            ]
        ),
        .testTarget(
            name: "VettIDDevicesUITests",
            dependencies: [
                "VettIDDevices",
                "VettIDDevicesUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
