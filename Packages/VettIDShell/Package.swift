// swift-tools-version: 6.0
import PackageDescription

// The app's shell (vettid-android `app/ui`): the drawer and its destinations, the avatar sheet, the owner check's
// banners (IOS-PLAN §8 I1.8, ID14), where the connect flow and an opened invitation link go (I2.1), the messages (I2.2),
// approvals, notifications and History (I2.3), the Vault (I3.1), Votes (IOS-PLAN §4.16).
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
        // TEST ONLY: the feed items of the shell's screen tests.
        .package(path: "../VettIDVault"),
        .package(path: "../VettIDUI"),
        .package(path: "../VettIDOnboarding"),
        .package(path: "../VettIDSettings"),
        .package(path: "../VettIDConnections"),
        .package(path: "../VettIDMessages"),
        .package(path: "../VettIDApprovals"),
        .package(path: "../VettIDNotifications"),
        .package(path: "../VettIDHistory"),
        .package(path: "../VettIDItems"),
        .package(path: "../VettIDVotes"),
    ],
    targets: [
        // What the shell decides (destinations, the account's lines, the notices' texts): no UI, so `swift test` runs
        // its tests on macOS.
        .target(
            name: "VettIDShell",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDOnboarding", package: "VettIDOnboarding"),
                .product(name: "VettIDConnections", package: "VettIDConnections"),
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
                .product(name: "VettIDConnections", package: "VettIDConnections"),
                .product(name: "VettIDMessages", package: "VettIDMessages"),
                .product(name: "VettIDApprovals", package: "VettIDApprovals"),
                .product(name: "VettIDNotifications", package: "VettIDNotifications"),
                .product(name: "VettIDHistory", package: "VettIDHistory"),
                .product(name: "VettIDItems", package: "VettIDItems"),
                .product(name: "VettIDVotes", package: "VettIDVotes"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDShellTests",
            dependencies: [
                "VettIDShell",
                .product(name: "VettIDConnections", package: "VettIDConnections"),
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
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "VettIDHistory", package: "VettIDHistory"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
