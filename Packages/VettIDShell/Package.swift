// swift-tools-version: 6.0
import PackageDescription

// The app's shell (vettid-android `app/ui`): the drawer and its destinations, the avatar sheet, the owner check's
// banners (IOS-PLAN §8 I1.8, ID14).
let package = Package(
    name: "VettIDShell",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDShell", targets: ["VettIDShell", "VettIDShellUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDKeys"),
        .package(path: "../VettIDUI"),
        .package(path: "../VettIDOnboarding"),
        .package(path: "../VettIDSettings"),
    ],
    targets: [
        // What the shell decides (destinations, the account's lines, the notices' texts): no UI, so `swift test` runs
        // its tests on macOS.
        .target(
            name: "VettIDShell",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDOnboarding", package: "VettIDOnboarding"),
            ]
        ),
        // The shell's views (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDShellUI",
            dependencies: [
                "VettIDShell",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDOnboarding", package: "VettIDOnboarding"),
                .product(name: "VettIDSettings", package: "VettIDSettings"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDShellTests",
            dependencies: [
                "VettIDShell",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDOnboarding", package: "VettIDOnboarding"),
            ]
        ),
        .testTarget(
            name: "VettIDShellUITests",
            dependencies: [
                "VettIDShell",
                "VettIDShellUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDOnboarding", package: "VettIDOnboarding"),
                .product(name: "VettIDSettings", package: "VettIDSettings"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDKeys", package: "VettIDKeys"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
