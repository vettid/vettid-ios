// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDUI",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VettIDUI", targets: ["VettIDUI"]),
    ],
    dependencies: [
        // The camera's shot handed over as zeroable bytes with its mirror flag (`PhotoBytes`).
        .package(path: "../VettIDMedia"),
    ],
    targets: [
        .target(
            name: "VettIDUI",
            dependencies: [.product(name: "VettIDMedia", package: "VettIDMedia")],
            resources: [
                .process("Resources/Brand.xcassets"),
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/Fonts"),
            ]
        ),
        .testTarget(name: "VettIDUITests", dependencies: ["VettIDUI"]),
    ]
)
