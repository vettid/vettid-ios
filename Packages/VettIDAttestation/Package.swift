// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDAttestation",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDAttestation", targets: ["VettIDAttestation"]),
    ],
    targets: [
        .target(name: "VettIDAttestation"),
        .testTarget(name: "VettIDAttestationTests", dependencies: ["VettIDAttestation"]),
    ]
)
