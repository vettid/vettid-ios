import Foundation
import Testing
@testable import VettIDUI

/// Tag colours (owner decisions of 2026-10-09): the registry's stored colour first, the least-used palette colour for
/// a tag without one, the hash colour until one is stored, `@profile` gold, ten clearly different hues, and every pair
/// readable (WCAG AA) in both themes. Mirrors vettid-android `TagColorsTest`.
struct TagColorsTests {
    @Test func theHashIsFnv1aOverUTF8() {
        // The published FNV-1a 32-bit vectors.
        #expect(TagColors.hash("") == 0x811C_9DC5)
        #expect(TagColors.hash("a") == 0xE40C_292C)
        #expect(TagColors.hash("foobar") == 0xBF9C_F968)
    }

    @Test func theSameTagHasTheSameFallbackColour() {
        for t in ["travel", "medical", "money", "family", "école", "家族"] {
            #expect(TagColors.index(t) == TagColors.index(t))
            #expect(TagColors.of(t, dark: false) == TagColors.of(t, dark: false))
            #expect(TagColors.index(t) == TagColors.index(" \(t)  "))
        }
        // §10.7 lower-cases ASCII letters only, as the vault does.
        #expect(TagColors.index("travel") == TagColors.index("TRAVEL"))
        #expect(TagColors.index("travel") == Int(TagColors.hash("travel") % 10))
        #expect(TagColors.normalize("  Work   Bag ") == "work bag")
        #expect(TagColors.normalize("ÉCOLE") == "École")
    }

    @Test func tagsSpreadOverThePalette() {
        var counts = [Int](repeating: 0, count: TagColors.light.count)
        let words = ["travel", "medical", "money", "family", "work", "home", "car", "school", "crypto", "identity"]
        let tags = (0..<2000).map { "\(words[$0 % words.count])\($0)" }
        for t in tags { counts[TagColors.index(t)] += 1 }
        let mean = tags.count / counts.count
        for (i, n) in counts.enumerated() {
            #expect(n > mean / 2 && n < mean * 3 / 2, "slot \(i) has \(n)")
        }
    }

    @Test func theSharedProfileIsGold() {
        #expect(TagColors.index("@profile") == -1)
        #expect(TagColors.of("@profile", dark: true).container == VettIDPalette.gold)
        #expect(TagColors.of("@profile", dark: false).container == VettIDPalette.gold)
        // Whatever the registry says.
        #expect(TagColors.of("@profile", dark: false, stored: TagColors.stored[0]) == TagColors.own)
        #expect(TagColors.own.container == VettIDColors.dark.avatar)
        // No other tag is gold.
        for c in TagColors.light + TagColors.dark { #expect(c.container != VettIDPalette.gold) }
    }

    @Test func everyPairMeetsAAInBothThemes() {
        #expect(TagColors.light.count == 10)
        #expect(TagColors.dark.count == TagColors.light.count)
        #expect(TagColors.names.count == TagColors.light.count)
        for (i, c) in (TagColors.light + TagColors.dark + [TagColors.own]).enumerated() {
            #expect(contrastRatio(c.onContainer, c.container) >= 4.5, "#\(i)")
        }
    }

    @Test func thePaletteHasNoLookAlikesInEitherThemeAndNothingGoldLike() {
        for palette in [TagColors.light, TagColors.dark] {
            let fills = palette.map(\.container) + [VettIDPalette.gold]
            for i in fills.indices {
                for j in (i + 1)..<fills.count {
                    #expect(oklabDistance(fills[i], fills[j]) >= 9, "\(i)/\(j)")
                }
            }
        }
        // No hue in gold's neighbourhood (OKLCH hue 58–125°) unless almost grey.
        for (i, c) in (TagColors.light + TagColors.dark).enumerated() {
            let (_, chroma, hue) = oklch(c.container)
            #expect(chroma < 0.07 || !(58...125).contains(hue), "#\(i) hue \(hue)")
        }
    }

    @Test func aPaletteColourIsStoredAsItsLightFill() {
        #expect(TagColors.stored[0] == "#f88d96")
        #expect(Set(TagColors.stored).count == 10)
        for (i, s) in TagColors.stored.enumerated() {
            #expect(s.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil, "\(s)")
            #expect(TagColors.parse(s) == TagColors.light[i].container)
            #expect(TagColors.slotOf(s) == i)
            #expect(TagColors.slotOf(s.uppercased()) == i)
            // Shown as its pair in each theme.
            #expect(TagColors.of("travel", dark: false, stored: s) == TagColors.light[i])
            #expect(TagColors.of("travel", dark: true, stored: s) == TagColors.dark[i])
        }
    }

    @Test func aStoredColourOutsideThePaletteIsShownAsIsAndReadable() {
        for s in ["#000000", "#ffffff", "#123456", "#ABCDEF", "#808080", "#ff0000", "#00ff00", "#7f7f7f"] {
            for dark in [false, true] {
                let c = TagColors.of("travel", dark: dark, stored: s)
                #expect(c.container == TagColors.parse(s))
                #expect(contrastRatio(c.onContainer, c.container) >= 4.5, "\(s)")
            }
        }
    }

    @Test func withoutAValidStoredColourTheHashColourShows() {
        let hash = TagColors.light[TagColors.index("travel")]
        let bad: [String?] = [nil, "", "red", "#fff", "#12345", "#1234567", "#12345g", "123456#", "#-12345", "# 12345", "#+12345"]
        for s in bad {
            #expect(TagColors.parse(s) == nil, "\(String(describing: s))")
            #expect(TagColors.of("travel", dark: false, stored: s) == hash)
        }
        #expect(TagColors.slotOf("#123456") == -1)
        #expect(TagColors.slotOf(nil) == -1)
    }

    @Test func thePickerMarksTheSlotShown() {
        #expect(TagColors.shownSlot("travel", stored: TagColors.stored[3]) == 3)
        #expect(TagColors.shownSlot("travel", stored: nil) == TagColors.index("travel"))
        #expect(TagColors.shownSlot("travel", stored: "#123456") == -1)
        #expect(TagColors.shownSlot("@profile", stored: nil) == -1)
    }

    // --- the least-used assignment ---

    /// Applies ``TagColors/next(_:)`` until every tag has a colour, as the app does, one `tag.set` at a time.
    private func assignAll(_ tags: [(String, String?)]) -> [String: String?] {
        var m = [String: String?]()
        for (t, c) in tags { m[t] = c }
        for _ in 0...tags.count {
            guard let (t, c) = TagColors.next(tags.map { ($0.0, m[$0.0] ?? nil) }) else { return m }
            #expect(TagColors.parse(m[t] ?? nil) == nil, "\(t) assigned twice")
            m[t] = c
        }
        Issue.record("more assignments than tags")
        return m
    }

    @Test func fiveNewTagsGetFiveDifferentColours() {
        let out = assignAll(["travel", "medical", "money", "family", "work"].map { ($0, nil) })
        #expect(Set(out.values.map { TagColors.slotOf($0) }).count == 5)
        // Ten tags: every palette colour once.
        let ten = assignAll((1...10).map { ("tag \($0)", nil) })
        #expect(Set(ten.values.map { TagColors.slotOf($0) }) == Set(0...9))
    }

    @Test func theLeastUsedColourWinsAndTiesGoToTheHashSlotThenPaletteOrder() throws {
        // Nothing used: every slot ties, so the tag takes its hash slot.
        let first = try #require(TagColors.next([("travel", nil)]))
        #expect(first == ("travel", TagColors.stored[TagColors.index("travel")]))
        // Every slot used once except one: that one, whatever the hash.
        let h = TagColors.index("travel")
        let free = (h + 3) % 10
        let used: [(String, String?)] = (0...9).filter { $0 != free }.map { ("t\($0)", TagColors.stored[$0]) }
        let second = try #require(TagColors.next(used + [("travel", nil)]))
        #expect(second == ("travel", TagColors.stored[free]))
        // The hash slot taken, the rest free: the first free one in palette order.
        let firstFree = h == 0 ? 1 : 0
        let third = try #require(TagColors.next([("x", TagColors.stored[h]), ("travel", nil)]))
        #expect(third == ("travel", TagColors.stored[firstFree]))
    }

    @Test func tagsAreAssignedInSortedNameOrderSoDevicesConverge() {
        let tags = ["Zoo", "apple", "medical", "b"]
        let a = assignAll(tags.map { ($0, nil) })
        let b = assignAll(tags.reversed().map { ($0, nil) })
        #expect(a == b)
        // The first chosen is the first by normalised name.
        #expect(TagColors.next(tags.map { ($0, nil) })?.0 == "apple")
    }

    @Test func theSharedProfileIsNeverAssignedAndColourlessTagsAloneAre() {
        #expect(TagColors.next([("@profile", nil)]) == nil)
        #expect(TagColors.next([("@profile", nil), ("travel", nil)])?.0 == "travel")
        // Stored colours are kept: nothing left to do.
        #expect(TagColors.next([("a", TagColors.stored[1]), ("b", "#123456")]) == nil)
        // An unreadable stored value counts as none.
        #expect(TagColors.next([("a", TagColors.stored[1]), ("b", "teal")])?.0 == "b")
    }

    @Test func storedColoursOutsideThePaletteCountForNoSlot() {
        let h = TagColors.index("travel")
        let tags: [(String, String?)] = (0..<10).map { ("o\($0)", "#12345\($0)") } + [("travel", nil)]
        let next = TagColors.next(tags)
        #expect(next?.0 == "travel")
        #expect(next?.1 == TagColors.stored[h])
    }

    // OKLab, as in the Android test. (Lab triples.)
    // swiftlint:disable large_tuple
    private func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    private func oklab(_ c: ThemeColor) -> (Double, Double, Double) {
        let r = lin(c.red), g = lin(c.green), b = lin(c.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    private func oklabDistance(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        let (l1, a1, b1) = oklab(a)
        let (l2, a2, b2) = oklab(b)
        return sqrt(pow(l1 - l2, 2) + pow(a1 - a2, 2) + pow(b1 - b2, 2)) * 100
    }

    private func oklch(_ c: ThemeColor) -> (Double, Double, Double) {
        let (l, a, b) = oklab(c)
        var hue = atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (l, sqrt(a * a + b * b), abs(hue))
    }
    // swiftlint:enable large_tuple
}
