// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDAltChan",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDAltChan", targets: ["VettIDAltChan"]),
    ],
    targets: [
        .target(name: "VettIDAltChan"),
        .testTarget(name: "VettIDAltChanTests", dependencies: ["VettIDAltChan"]),
    ]
)
