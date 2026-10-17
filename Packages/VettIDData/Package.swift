// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDData",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VettIDData", targets: ["VettIDData"]),
    ],
    targets: [
        .target(name: "VettIDData"),
        .testTarget(name: "VettIDDataTests", dependencies: ["VettIDData"]),
    ]
)
