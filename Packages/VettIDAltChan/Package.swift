// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDAltChan",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDAltChan", targets: ["VettIDAltChan"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
    ],
    targets: [
        .target(name: "VettIDAltChan", dependencies: ["VettIDCrypto"]),
        .testTarget(
            name: "VettIDAltChanTests",
            dependencies: ["VettIDAltChan", "VettIDCrypto"],
            exclude: ["Resources/SOURCE.md"],
            resources: [.copy("Resources/vectors")]
        ),
    ]
)
