// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDCrypto",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDCrypto", targets: ["VettIDCrypto"]),
    ],
    targets: [
        .target(name: "VettIDCrypto"),
        .testTarget(name: "VettIDCryptoTests", dependencies: ["VettIDCrypto"]),
    ]
)
