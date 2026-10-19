// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "repro",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Lib"),
        .executableTarget(name: "repro", dependencies: ["Lib"]),
    ]
)
