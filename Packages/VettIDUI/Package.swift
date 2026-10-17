// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VettIDUI",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VettIDUI", targets: ["VettIDUI"]),
    ],
    targets: [
        .target(
            name: "VettIDUI",
            resources: [
                .process("Resources/Brand.xcassets"),
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/Fonts"),
            ]
        ),
        .testTarget(name: "VettIDUITests", dependencies: ["VettIDUI"]),
    ]
)
