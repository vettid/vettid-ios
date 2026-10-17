import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDUI

/// Text and icon pairs used by the components meet WCAG AA: 4.5:1 for body text, 3:1 for large text and icons.
/// Mirrors vettid-android `ContrastTest`.
struct ContrastTests {
    @Test func contrastOfKnownPairs() {
        #expect(abs(contrastRatio(ThemeColor(0x000000), ThemeColor(0xFFFFFF)) - 21) < 0.01)
        #expect(abs(contrastRatio(ThemeColor(0xFFFFFF), ThemeColor(0xFFFFFF)) - 1) < 0.0001)
    }

    @Test func brandGoldIsTheWebsiteToken() {
        #expect(VettIDPalette.gold == ThemeColor(0xFFC125))
        // Bright gold is a fill colour only: on white it fails even the 3:1 icon minimum.
        #expect(contrastRatio(VettIDPalette.gold, VettIDPalette.white) < 3)
        #expect(VettIDColors.dark.primary == VettIDPalette.gold)
        #expect(VettIDColors.light.primaryContainer == VettIDPalette.gold)
        #expect(VettIDColors.light.primary == VettIDPalette.goldDeep)
    }

    @Test(arguments: [("dark", VettIDColors.dark), ("light", VettIDColors.light)])
    func schemeMeetsAA(_ theme: String, _ c: VettIDColors) {
        func expectContrast(_ name: String, _ fg: ThemeColor, _ bg: ThemeColor, _ minimum: Double) {
            let ratio = contrastRatio(fg, bg)
            #expect(ratio >= minimum, "\(theme) \(name): \(ratio) < \(minimum)")
        }
        let surfaces = [
            ("background", c.background), ("surfaceContainerLow", c.surfaceContainerLow), ("surfaceContainer", c.surfaceContainer),
        ]
        for (name, bg) in surfaces {
            expectContrast("onSurface/\(name)", c.onSurface, bg, 4.5)
            expectContrast("onSurfaceVariant/\(name)", c.onSurfaceVariant, bg, 4.5)
            expectContrast("primary/\(name)", c.primary, bg, 4.5)
        }
        expectContrast("onSurface/card", c.onSurface, c.card, 4.5)
        expectContrast("onSurfaceVariant/card", c.onSurfaceVariant, c.card, 4.5)
        expectContrast("onSurfaceVariant/groupedBackground", c.onSurfaceVariant, c.groupedBackground, 4.5)
        expectContrast("onSurface/surfaceContainerHigh", c.onSurface, c.surfaceContainerHigh, 4.5)
        expectContrast("primary/surfaceContainerHigh", c.primary, c.surfaceContainerHigh, 3)
        expectContrast("onPrimaryContainer/primaryContainer", c.onPrimaryContainer, c.primaryContainer, 4.5)
        expectContrast("onTile/tile", c.onTile, c.tile, 4.5)
        expectContrast("onFavoriteTile/favoriteTile", c.onFavoriteTile, c.favoriteTile, 4.5)
        // A favourite tile must stand apart from the screen and from a plain tile.
        expectContrast("favoriteTile/background", c.favoriteTile, c.background, 3)
        expectContrast("onAvatar/avatar", c.onAvatar, c.avatar, 4.5)
        expectContrast("error/background", c.error, c.background, 4.5)
    }
}

/// History's category colours: one fixed colour per hue, readable (WCAG AA) in both themes.
/// Mirrors vettid-android `CategoryColorsTest`.
struct CategoryColorsTests {
    @Test func everyHueHasAColourInBothThemes() {
        #expect(Set(CategoryColors.light.keys) == Set(CategoryHue.allCases))
        #expect(Set(CategoryColors.dark.keys) == Set(CategoryHue.allCases))
        // Distinct within a theme, so that the groups can be told apart.
        #expect(Set(CategoryColors.light.values.map(\.container)).count == CategoryHue.allCases.count)
        #expect(Set(CategoryColors.dark.values.map(\.container)).count == CategoryHue.allCases.count)
    }

    @Test func theVaultIsTheMembersGold() {
        #expect(CategoryColors.of(.gold, dark: false) == TagColors.own)
        #expect(CategoryColors.of(.gold, dark: true) == TagColors.own)
    }

    @Test func everyPairMeetsAAInBothThemes() {
        let light = CategoryColors.light.map { ("light \($0.key)", $0.value) }
        let dark = CategoryColors.dark.map { ("dark \($0.key)", $0.value) }
        for (hue, c) in light + dark {
            #expect(contrastRatio(c.onContainer, c.container) >= 4.5, "\(hue)")
        }
    }
}

/// Every symbol of the table exists in SF Symbols on this iOS.
struct SymbolTests {
    @Test func everySymbolExists() {
        for s in VettIDSymbol.allCases {
            #expect(UIImageExists(systemName: s.rawValue), "\(s) → \(s.rawValue)")
        }
    }
}

private func UIImageExists(systemName: String) -> Bool { UIImage(systemName: systemName) != nil }

/// The bundled fonts register and each weight the type scale uses resolves to its face.
struct FontTests {
    @Test func everyWeightOfTheScaleResolves() {
        VettIDFonts.register()
        for style in VettIDTextStyle.allCases {
            let name = VettIDFonts.postScriptName(style.spec.family, style.spec.weight)
            #expect(UIFont(name: name, size: 12) != nil, "\(style): \(name)")
        }
        for weight in [Font.Weight.regular, .medium, .semibold, .bold] {
            #expect(UIFont(name: VettIDFonts.postScriptName(.body, weight), size: 12) != nil)
            #expect(UIFont(name: VettIDFonts.postScriptName(.heading, weight), size: 12) != nil)
        }
    }
}
