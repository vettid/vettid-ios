import Foundation
import VettIDCrypto

/// Member-defined categories (VAULT-MESSAGING §10.7: any `[a-z][a-z0-9_]{0,31}`; the recommended list is only a
/// suggestion). The member types a name ("Loyalty cards"); the app derives the identifier (`loyalty_cards`) and shows a
/// custom one humanized from it. Mirrors vettid-android `ItemCategories`.
public enum ItemCategories {
    public static let maxID = 32

    /// Why no identifier could be derived from a name.
    public enum Problem: Sendable {
        /// Nothing usable is left: no letter or digit of a-z, 0-9 (after removing accents).
        case empty
        /// The identifier would start with a digit; a category starts with a letter.
        case startsWithDigit
    }

    /// The identifier a name gives ([id]), or why it gives none ([problem]).
    public struct Derived: Equatable, Sendable {
        public let id: String?
        public let problem: Problem?

        /// Whether [id] is one of the recommended categories (choosing it selects that one).
        public var recommended: Bool { id.map(ItemCategories.isRecommended) ?? false }
    }

    /// The identifier of a typed category name: accents removed, lower case, spaces and hyphens become `_`, other
    /// characters are dropped, runs of `_` collapse, at most ``maxID`` characters; it must start with a letter.
    public static func derive(_ name: String) -> Derived {
        // NFD, then the non-spacing marks (Mn) removed, as vettid-android's `Normalizer` and `\p{Mn}`.
        let plain = String(String.UnicodeScalarView(
            name.trimmingCharacters(in: .whitespacesAndNewlines).decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { $0.properties.generalCategory != .nonspacingMark }
        ))
        var id = ""
        var underscore = false
        for c in plain.lowercased().replacingOccurrences(of: "ß", with: "ss").unicodeScalars {
            // Java's `\s` (ASCII white space) and `-` separate words.
            let mapped: Unicode.Scalar? = " \t\n\u{0B}\u{0C}\r-_".unicodeScalars.contains(c) ? "_"
                : (("a"..."z").contains(c) || ("0"..."9").contains(c) ? c : nil)
            guard let m = mapped else { continue }
            if m == "_" {
                if !underscore { id.unicodeScalars.append(m) }
                underscore = true
            } else {
                id.unicodeScalars.append(m)
                underscore = false
            }
        }
        id = trimUnderscores(id)
        id = trimUnderscores(String(id.prefix(maxID)))
        guard let first = id.unicodeScalars.first else { return Derived(id: nil, problem: .empty) }
        guard ("a"..."z").contains(first) else { return Derived(id: nil, problem: .startsWithDigit) }
        return ItemSpec.isValidCategory(id) ? Derived(id: id, problem: nil) : Derived(id: nil, problem: .empty)
    }

    private static func trimUnderscores(_ s: String) -> String {
        var t = Substring(s)
        while t.first == "_" { t.removeFirst() }
        while t.last == "_" { t.removeLast() }
        return String(t)
    }

    /// A custom category as shown: `loyalty_cards` → "Loyalty cards".
    public static func humanize(_ id: String) -> String {
        let s = id.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    public static func isRecommended(_ id: String) -> Bool { ItemSpec.recommendedCategories.contains(id) }

    /// The member's own categories among [categories] (valid, not recommended), distinct and sorted.
    public static func customs(_ categories: some Sequence<String>) -> [String] {
        Set(categories.filter { ItemSpec.isValidCategory($0) && !isRecommended($0) }).sorted(by: ItemSpec.utf8Less)
    }
}
