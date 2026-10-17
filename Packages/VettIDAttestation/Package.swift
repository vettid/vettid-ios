// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDAttestation",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDAttestation", targets: ["VettIDAttestation"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
    ],
    targets: [
        .target(name: "VettIDAttestation", dependencies: ["VettIDCrypto"]),
        .testTarget(
            name: "VettIDAttestationTests",
            dependencies: ["VettIDAttestation", "VettIDCrypto"],
            exclude: ["Resources/SOURCE.md"],
            resources: [.copy("Resources/nitro"), .copy("Resources/manifest"), .copy("Resources/vectors")]
        ),
    ]
)
