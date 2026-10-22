// swift-tools-version: 6.0
import PackageDescription

// The Vault (vettid-android `feature/items`): the member's items and their tags (IOS-PLAN §8 I3.1; ANDROID-PLAN §4
// Vault; VAULT-ITEMS): the Vault list, an item's screen, adding and editing from the templates, and the tags.
let package = Package(
    name: "VettIDItems",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VettIDItems", targets: ["VettIDItems", "VettIDItemsUI"]),
    ],
    dependencies: [
        .package(path: "../VettIDData"),
        .package(path: "../VettIDVault"),
        .package(path: "../VettIDUI"),
        // The phone numbers of §10.7 "Phone values" (VAULT-MESSAGING 0.55.0): libphonenumber's metadata, as-you-type and
        // display formats (IOS-PLAN §4.8; the owner accepted the dependency).
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", exact: "5.0.10"),
    ],
    targets: [
        // The view models, their state and every text of the Vault (vettid-android's `strings.xml` and
        // `strings_sharing.xml`): no UI, so `swift test` runs their tests on macOS.
        .target(
            name: "VettIDItems",
            dependencies: [
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDVault", package: "VettIDVault"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        // The screens (iOS only: VettIDUI is UIKit-based; on macOS this target compiles empty).
        .target(
            name: "VettIDItemsUI",
            dependencies: [
                "VettIDItems",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "VettIDItemsTests",
            dependencies: [
                "VettIDItems",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
            ],
            // vettid-vault's registry of templates (Resources/SOURCE.md).
            exclude: ["Resources/SOURCE.md"],
            resources: [.copy("Resources/item-templates.json")]
        ),
        .testTarget(
            name: "VettIDItemsUITests",
            dependencies: [
                "VettIDItems",
                "VettIDItemsUI",
                .product(name: "VettIDData", package: "VettIDData"),
                .product(name: "VettIDDataTesting", package: "VettIDData"),
                .product(name: "VettIDUI", package: "VettIDUI", condition: .when(platforms: [.iOS])),
            ]
        ),
    ]
)
