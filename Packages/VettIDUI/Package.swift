// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDUI",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VettIDUI", targets: ["VettIDUI"]),
    ],
    targets: [
        .target(name: "VettIDUI"),
        .testTarget(name: "VettIDUITests", dependencies: ["VettIDUI"]),
    ]
)
