// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDNotify",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VettIDNotify", targets: ["VettIDNotify"]),
    ],
    targets: [
        .target(name: "VettIDNotify"),
        .testTarget(name: "VettIDNotifyTests", dependencies: ["VettIDNotify"]),
    ]
)
