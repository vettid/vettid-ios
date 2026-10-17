// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDKeys",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VettIDKeys", targets: ["VettIDKeys"]),
    ],
    targets: [
        .target(name: "VettIDKeys"),
        .testTarget(name: "VettIDKeysTests", dependencies: ["VettIDKeys"]),
    ]
)
