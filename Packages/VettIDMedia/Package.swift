// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDMedia",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VettIDMedia", targets: ["VettIDMedia"]),
    ],
    targets: [
        .target(name: "VettIDMedia"),
        .testTarget(name: "VettIDMediaTests", dependencies: ["VettIDMedia"]),
    ]
)
