// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDKeys",
    // macOS only so that `swift test` runs the pure parts (the file store, the seed wrapper, the cleanup) without a
    // simulator; the app is iOS only, and the keychain's tests run on the simulator.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDKeys", targets: ["VettIDKeys"]),
        // TEST ONLY: software keys behind the same protocols as the Secure Enclave's (IOS-PLAN §6.1, §6.3), for tests
        // and, later, the simulator dev stack. Never linked by a Release or Staging app (release check: its name and its
        // "VETTID TEST ONLY" marker).
        .library(name: "VettIDKeysTesting", targets: ["VettIDKeysTesting"]),
    ],
    dependencies: [
        .package(path: "../VettIDCrypto"),
    ],
    targets: [
        .target(name: "VettIDKeys", dependencies: ["VettIDCrypto"]),
        .target(name: "VettIDKeysTesting", dependencies: ["VettIDKeys", "VettIDCrypto"]),
        .testTarget(name: "VettIDKeysTests", dependencies: ["VettIDKeys", "VettIDKeysTesting", "VettIDCrypto"]),
    ]
)
