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
        // ML-KEM-768 and SHA-3 from the vendored mlkem-native (Apache-2.0 OR ISC OR MIT; Sources/CMLKEM/SOURCE.md).
        // One compilation unit: vettid_mlkem.c includes the library's monolithic mlkem_native.c.
        .target(
            name: "CMLKEM",
            exclude: ["mlkem-native/LICENSE", "SOURCE.md"],
            sources: ["vettid_mlkem.c"],
            cSettings: [.headerSearchPath("."), .headerSearchPath("mlkem-native")]
        ),
        .target(
            name: "VettIDCrypto",
            dependencies: ["CMLKEM", .product(name: "Clibsodium", package: "swift-sodium")],
            // The password estimator's word lists, from vettid-vault vms/recovery (Resources/passwords/SOURCE.md).
            resources: [.copy("Resources/passwords")]
        ),
        .testTarget(
            name: "VettIDCryptoTests",
            dependencies: ["VettIDCrypto"],
            exclude: ["Resources/SOURCE.md"],
            resources: [.copy("Resources/vectors"), .copy("Resources/reference")]
        ),
    ]
)
