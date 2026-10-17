// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDCrypto",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDCrypto", targets: ["VettIDCrypto"]),
    ],
    dependencies: [
        // libsodium (ISC) for Ed25519 (deterministic signatures), XChaCha20-Poly1305 and Argon2id (IOS-PLAN ID6).
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
    ],
    targets: [
        .target(
            name: "VettIDCrypto",
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")]
        ),
        .testTarget(
            name: "VettIDCryptoTests",
            dependencies: ["VettIDCrypto"],
            resources: [.copy("Resources/vectors")]
        ),
    ]
)
