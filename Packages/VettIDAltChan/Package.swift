// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDAltChan",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDAltChan", targets: ["VettIDAltChan"]),
        // TEST ONLY: the TEST iOS attester (a port of vettid-vault's TEST App Attest authority) and the local dev
        // stack's helpers, for tests and the dev stack. Never linked by a Release or Staging app (release check: its name
        // and its "VETTID TEST ONLY" marker). It lives here, not in VettIDTesting, because it implements this package's
        // `Attester` while this package's tests use VettIDTesting: VettIDTesting depending on VettIDAltChan would close
        // a package cycle.
        .library(name: "VettIDAltChanTesting", targets: ["VettIDAltChanTesting"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDAttestation"),
        .package(path: "../VettIDRelay"),
        // TEST ONLY: the fake HTTP server of the tests.
        .package(path: "../VettIDTesting"),
        // TEST ONLY: X.509 for the TEST App Attest certificates of VettIDAltChanTesting (IOS-PLAN §8 I1.3).
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
    ],
    targets: [
        .target(name: "VettIDAltChan", dependencies: ["VettIDCrypto", "VettIDAttestation", "VettIDRelay"]),
        .target(
            name: "VettIDAltChanTesting",
            dependencies: [
                "VettIDAltChan", "VettIDCrypto", "VettIDAttestation", "VettIDRelay",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .testTarget(
            name: "VettIDAltChanTests",
            dependencies: [
                "VettIDAltChan", "VettIDAltChanTesting", "VettIDCrypto", "VettIDAttestation", "VettIDRelay", "VettIDTesting",
                .product(name: "X509", package: "swift-certificates"),
            ],
            exclude: ["Resources/SOURCE.md", "Resources/appattest"],
            resources: [.copy("Resources/vectors")]
        ),
    ]
)
