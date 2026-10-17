import SwiftUI

/// A tag chip's fill and the text and icons on it.
public struct TagColor: Hashable, Sendable {
    public let container: ThemeColor
    public let onContainer: ThemeColor

    public init(_ container: ThemeColor, _ onContainer: ThemeColor) {
        self.container = container
        self.onContainer = onContainer
    }
}

/// Tag colours (owner decisions of 2026-10-09): every tag has one colour, the same everywhere and on every device.
/// The colour is the one stored in the vault's tag registry (VAULT-MESSAGING §10.8 `color`, `#rrggbb`): a palette
/// colour stored as its light fill (``stored``) shows as its pair in each theme, any other `#rrggbb` as is, with
/// black or white text, whichever reads better. A tag with none is given the least-used palette colour (``next(_:)``),
/// which the app stores; until then it shows its hash colour (FNV-1a of the normalised name, ``index(_:)``). The
/// palette is ten clearly different hues, as pairs that meet WCAG AA for text in each theme; none is gold, which stays
/// the member's own: the reserved `@profile` tag ("Shared profile") always takes the gold of the member's avatar and
/// never has a colour stored.
///
/// Mirrors vettid-android `core/ui/…/theme/TagColors.kt`.
public enum TagColors {
    /// The reserved tag of the member's shared profile (VAULT-ITEMS §10.8).
    public static let ownTag = "@profile"

    /// The palette's hues, by slot (for accessibility labels and tests).
    public static let names = ["red", "orange", "green", "teal", "blue", "indigo", "violet", "pink", "brown", "slate"]

    /// Light theme: mid-light fills with deep text of the same hue. Order is part of the hash fallback's mapping and
    /// the least-used tie-break: never reorder (stored colours do not depend on it).
    public static let light: [TagColor] = [
        TagColor(ThemeColor(0xF88D96), ThemeColor(0x42151B)), // red
        TagColor(ThemeColor(0xFEA669), ThemeColor(0x3E1C01)), // orange
        TagColor(ThemeColor(0x99D079), ThemeColor(0x162E06)), // green
        TagColor(ThemeColor(0x37CCAC), ThemeColor(0x012E25)), // teal
        TagColor(ThemeColor(0x59BBFB), ThemeColor(0x022A41)), // blue
        TagColor(ThemeColor(0xB2CAFE), ThemeColor(0x152448)), // indigo
        TagColor(ThemeColor(0xB0A2FE), ThemeColor(0x271F46)), // violet
        TagColor(ThemeColor(0xED9EE5), ThemeColor(0x391836)), // pink
        TagColor(ThemeColor(0xE3C2B7), ThemeColor(0x371F17)), // brown
        TagColor(ThemeColor(0xA6B3C1), ThemeColor(0x1D2732)), // slate
    ]

    /// Dark theme: the same hues, deep fills with pale text.
    public static let dark: [TagColor] = [
        TagColor(ThemeColor(0x8C2B3B), ThemeColor(0xFEE8E9)), // red
        TagColor(ThemeColor(0x602D00), ThemeColor(0xFEEADD)), // orange
        TagColor(ThemeColor(0x224801), ThemeColor(0xE6F3DF)), // green
        TagColor(ThemeColor(0x036150), ThemeColor(0xDBF6ED)), // teal
        TagColor(ThemeColor(0x025884), ThemeColor(0xE0F1FF)), // blue
        TagColor(ThemeColor(0x1A3680), ThemeColor(0xE7EFFE)), // indigo
        TagColor(ThemeColor(0x5E4DA1), ThemeColor(0xEEECFE)), // violet
        TagColor(ThemeColor(0x783274), ThemeColor(0xFBE8F8)), // pink
        TagColor(ThemeColor(0x72564D), ThemeColor(0xFFE9E2)), // brown
        TagColor(ThemeColor(0x333E4A), ThemeColor(0xE3F0FE)), // slate
    ]

    /// What the registry stores for each slot (§10.8 `#rrggbb`, lower case): the light theme's fill.
    public static let stored: [String] = light.map { hex($0.container) }

    /// The member's own colour (the avatar's gold), for ``ownTag``.
    public static let own = TagColor(VettIDPalette.gold, VettIDPalette.ink)

    private static let inkDark = ThemeColor(0x000000)
    private static let inkLight = ThemeColor(0xFFFFFF)

    /// The tag as hashed, normalised as VAULT-ITEMS §10.7 does: outer spaces trimmed, runs of spaces made one, ASCII
    /// letters lower case.
    public static func normalize(_ tag: String) -> String {
        var out = ""
        var space = false
        let scalars = tag.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, scalars[start] == " " { start = scalars.index(after: start) }
        while end > start, scalars[scalars.index(before: end)] == " " { end = scalars.index(before: end) }
        for c in scalars[start..<end] {
            if c == " " {
                if !space { out.unicodeScalars.append(c) }
                space = true
                continue
            }
            space = false
            if ("A"..."Z").contains(c), let lower = Unicode.Scalar(c.value + 32) {
                out.unicodeScalars.append(lower)
            } else {
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// 32-bit FNV-1a over the UTF-8 bytes of the ``normalize(_:)``d tag.
    public static func hash(_ tag: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for b in normalize(tag).utf8 {
            h = (h ^ UInt32(b)) &* 0x0100_0193
        }
        return h
    }

    /// The hash slot of a tag: ``hash(_:)`` modulo the palette size; -1 for ``ownTag``.
    public static func index(_ tag: String) -> Int {
        isOwn(tag) ? -1 : Int(hash(tag) % UInt32(light.count))
    }

    public static func isOwn(_ tag: String) -> Bool { normalize(tag) == ownTag }

    /// Exactly `#` and six hex digits (either case) parsed, opaque; nil for anything else.
    public static func parse(_ color: String?) -> ThemeColor? {
        guard let color, color.utf8.count == 7, color.hasPrefix("#") else { return nil }
        let digits = color.dropFirst()
        guard digits.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }),
              let value = UInt32(digits, radix: 16)
        else { return nil }
        return ThemeColor(value)
    }

    /// The palette slot of a stored colour (any case); -1 when it is not a palette colour.
    public static func slotOf(_ color: String?) -> Int {
        guard let color else { return -1 }
        return stored.firstIndex(of: color.lowercased()) ?? -1
    }

    /// The colours of a tag in a theme; [stored] is the registry's colour for it, if any.
    public static func of(_ tag: String, dark: Bool, stored: String? = nil) -> TagColor {
        let palette = dark ? self.dark : light
        if isOwn(tag) { return own }
        let slot = slotOf(stored)
        if slot >= 0 { return palette[slot] }
        if let other = parse(stored) { return TagColor(other, readableOn(other)) }
        return palette[index(tag)]
    }

    /// The palette slot a tag shows with [stored] (its stored one, else its hash slot); -1 for a colour outside the
    /// palette or ``ownTag``.
    public static func shownSlot(_ tag: String, stored: String?) -> Int {
        if isOwn(tag) { return -1 }
        let slot = slotOf(stored)
        if slot >= 0 { return slot }
        if parse(stored) != nil { return -1 }
        return index(tag)
    }

    /// Black or white on [fill], whichever contrasts more.
    public static func readableOn(_ fill: ThemeColor) -> ThemeColor {
        contrastRatio(inkDark, fill) >= contrastRatio(inkLight, fill) ? inkDark : inkLight
    }

    /// The next colour to store (owner decision 2026-10-09): of the member's [tags] (tag to stored colour) without a
    /// colour, the first by normalised name, with the palette colour the fewest of their tags have (stored colours
    /// outside the palette count for none); a tie goes to the tag's hash slot when it is among the least used, else to
    /// the first of them in palette order. Nil when every tag has a colour. `@` tags are never coloured. Applied one at
    /// a time, in this order, two devices assigning at once pick the same colours.
    public static func next(_ tags: [(String, String?)]) -> (String, String)? {
        let mine = tags.filter { !$0.0.hasPrefix("@") }
        let candidates = mine.filter { parse($0.1) == nil }.map(\.0)
        guard let tag = candidates.min(by: { a, b in
            let na = normalize(a), nb = normalize(b)
            return na != nb ? na.utf16.lexicographicallyPrecedes(nb.utf16) : a.utf16.lexicographicallyPrecedes(b.utf16)
        }) else { return nil }
        var counts = [Int](repeating: 0, count: light.count)
        for (_, c) in mine {
            let s = slotOf(c)
            if s >= 0 { counts[s] += 1 }
        }
        let least = counts.min() ?? 0
        let h = index(tag)
        let slot = counts[h] == least ? h : (counts.firstIndex(of: least) ?? h)
        return (tag, stored[slot])
    }

    /// A stored colour (`#rrggbb`), ASCII lower case.
    private static func hex(_ c: ThemeColor) -> String {
        let digits = String(c.rgb, radix: 16)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }
}

public extension EnvironmentValues {
    /// The colours the vault's tag registry stores (§10.8), by normalised tag; set at the root of the UI from the
    /// registry as last listed, empty until it is (tags then show their hash colours).
    @Entry var vettIDTagColors: [String: String] = [:]
}

/// History's category hues (owner request 2026-10-09): unlocks green, security amber, blocked and dropped red,
/// connections teal, messages blue, the vault gold, devices purple, agents orange, location indigo, account grey.
/// Pale fills with deep text of the same hue in the light theme, deep fills with pale text in the dark one, every
/// pair WCAG AA; the vault's gold is the member's own (``TagColors/own``).
///
/// Mirrors vettid-android `core/ui/…/theme/CategoryColors.kt`.
public enum CategoryHue: CaseIterable, Sendable {
    case green, amber, red, teal, blue, gold, purple, orange, indigo, grey
}

public enum CategoryColors {
    public static let light: [CategoryHue: TagColor] = [
        .green: TagColor(ThemeColor(0xC2EFC4), ThemeColor(0x00210A)),
        .amber: TagColor(ThemeColor(0xFFDF9E), ThemeColor(0x261A00)),
        .red: TagColor(ThemeColor(0xFFDAD6), ThemeColor(0x410002)),
        .teal: TagColor(ThemeColor(0xB3EDE3), ThemeColor(0x00201C)),
        .blue: TagColor(ThemeColor(0xD8E2FF), ThemeColor(0x001A41)),
        .gold: TagColors.own,
        .purple: TagColor(ThemeColor(0xF0DBFF), ThemeColor(0x2C0051)),
        .orange: TagColor(ThemeColor(0xFFDBC8), ThemeColor(0x311300)),
        .indigo: TagColor(ThemeColor(0xE0E0FF), ThemeColor(0x13126B)),
        .grey: TagColor(ThemeColor(0xE2E2E6), ThemeColor(0x1A1C1E)),
    ]

    public static let dark: [CategoryHue: TagColor] = [
        .green: TagColor(ThemeColor(0x1B5E2A), ThemeColor(0xC2EFC4)),
        .amber: TagColor(ThemeColor(0x5C4300), ThemeColor(0xFFDF9E)),
        .red: TagColor(ThemeColor(0x8C1D18), ThemeColor(0xFFDAD6)),
        .teal: TagColor(ThemeColor(0x005047), ThemeColor(0xB3EDE3)),
        .blue: TagColor(ThemeColor(0x1F438F), ThemeColor(0xD8E2FF)),
        .gold: TagColors.own,
        .purple: TagColor(ThemeColor(0x6A1B9A), ThemeColor(0xF0DBFF)),
        .orange: TagColor(ThemeColor(0x723600), ThemeColor(0xFFDBC8)),
        .indigo: TagColor(ThemeColor(0x2E2D8C), ThemeColor(0xE0E0FF)),
        .grey: TagColor(ThemeColor(0x45474A), ThemeColor(0xE2E2E6)),
    ]

    public static func of(_ hue: CategoryHue, dark: Bool) -> TagColor {
        // Every hue is in both tables (CategoryColorsTests).
        (dark ? self.dark : light)[hue] ?? TagColors.own
    }
}
