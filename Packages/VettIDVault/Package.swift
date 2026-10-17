// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDVault",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDVault", targets: ["VettIDVault"]),
    ],
    targets: [
        .target(name: "VettIDVault"),
        .testTarget(name: "VettIDVaultTests", dependencies: ["VettIDVault"]),
    ]
)
