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
    ],
    targets: [
        .target(
            name: "VettIDNotify",
            dependencies: [.product(name: "VettIDData", package: "VettIDData")],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(name: "VettIDNotifyTests", dependencies: ["VettIDNotify"]),
    ]
)
