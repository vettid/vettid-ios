// swift-tools-version: 6.0
import PackageDescription

// The WebRTC media engine of the calls (vettid-android `WebRtcMediaEngine`, `MediaDiagnostics`, `MediaLogGuard`;
// VAULT-MESSAGING §10.10, CALLS-PLAN §12). It is a package of its own so that `VettIDCalls` builds and tests without the
// media stack's binary (about 700 MB to fetch). No app target links this package yet.
//
// The stack is webrtc-sdk's iOS and macOS build, release 150.7871.04 of `webrtc-sdk/Specs`, from libwebrtc commit
// a545de45 (the same libwebrtc as vettid-android's `io.github.webrtc-sdk:android:150.7871.04`). BSD-3-Clause.
let package = Package(
    name: "VettIDCallsWebRTC",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDCallsWebRTC", targets: ["VettIDCallsWebRTC"]),
    ],
    dependencies: [
        .package(path: "../VettIDCalls"),
        .package(path: "../VettIDCrypto"),
        .package(path: "../VettIDVault"),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/webrtc-sdk/Specs/releases/download/150.7871.04/WebRTC.xcframework.zip",
            checksum: "9532fe3ce47507c304f37a4355b907be1e89967971d614a04603005a546249be"
        ),
        .target(
            name: "VettIDCallsWebRTC",
            dependencies: [
                "WebRTC",
                .product(name: "VettIDCalls", package: "VettIDCalls"),
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
                .product(name: "VettIDVault", package: "VettIDVault"),
            ]
        ),
        .testTarget(
            name: "VettIDCallsWebRTCTests",
            dependencies: [
                "VettIDCallsWebRTC",
                "WebRTC",
                .product(name: "VettIDCalls", package: "VettIDCalls"),
                .product(name: "VettIDCrypto", package: "VettIDCrypto"),
                .product(name: "VettIDVault", package: "VettIDVault"),
            ]
        ),
    ]
)
