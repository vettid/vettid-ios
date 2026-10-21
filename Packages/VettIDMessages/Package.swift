// swift-tools-version: 6.0
import PackageDescription

// Messages (vettid-android `feature/messages`): the conversations, a conversation with its paging and composer, the
// new-message picker, the link rule of message text (IOS-PLAN §8 I2.2), and photo attachments with their viewer (I2.4).
let package = Package(
    name: "VettIDMessages",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDMessages", targets: ["VettIDMessages", "VettIDMessagesUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDData"),
        .package(path: "../VettIDMedia"),
        .package(path: "../VettIDUI"),
    ],
    targets: [
        // The view models and their state: no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDMessages",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDMedia", package: "VettIDMedia"),
            ]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDMessagesUI",
            dependencies: [
                "VettIDMessages",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDMedia", package: "VettIDMedia"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDMessagesTests",
            dependencies: [
                "VettIDMessages",
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
                .product(name: "VettIDMedia", package: "VettIDMedia"),
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
            ]
        ),
        .testTarget(
            name: "VettIDMessagesUITests",
            dependencies: [
                "VettIDMessages",
                "VettIDMessagesUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDMedia", package: "VettIDMedia"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
