// swift-tools-version: 6.0
import PackageDescription

// Photos in memory (vettid-android `:core:media`, IOS-PLAN §5): bounds, orientation, downscaling, JPEG without metadata,
// thumbnails, sniffing and bounded decoding with ImageIO, the memory-only cache and the share offers. Nothing here writes
// a file. No UIKit: `swift test` runs every test on macOS.
let package = Package(
    name: "VettIDMedia",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDMedia", targets: ["VettIDMedia"]),
    ],
    targets: [
        .target(name: "VettIDMedia"),
        .testTarget(name: "VettIDMediaTests", dependencies: ["VettIDMedia"]),
    ]
)
