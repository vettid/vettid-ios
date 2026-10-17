// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDRelay",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDRelay", targets: ["VettIDRelay"]),
    ],
    targets: [
        .target(name: "VettIDRelay"),
        .testTarget(name: "VettIDRelayTests", dependencies: ["VettIDRelay"]),
    ]
)
