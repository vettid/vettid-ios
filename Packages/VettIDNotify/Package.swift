// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDNotify",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDNotify", targets: ["VettIDNotify"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDVault"),
    ],
    targets: [
        .target(
            name: "VettIDNotify",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "VettIDNotifyTests",
            dependencies: [
                "VettIDNotify",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
            ]
        ),
    ]
)
