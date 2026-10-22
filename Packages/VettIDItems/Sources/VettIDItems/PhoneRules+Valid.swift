import Foundation

/// libphonenumber's `isValidNumber` and `format` over the same metadata as ``PhoneRules`` (PhoneNumberKit's validity and
/// formats differ from libphonenumber's on some numbers: the Caribbean 7-digit numbers, the Channel Islands, national
/// prefix transforms, non-geographic codes, formats without an international form). Written to give Android's results.
extension PhoneRules {
    /// `getNumberTypeHelper(...) != UNKNOWN`: the national number matches the territory's general description and one of
    /// its number types (the type's own lengths first, when the metadata gives them).
    static func hasType(_ national: String, _ t: Territory) -> Bool {
        guard matchesEntirely(t.generalPattern, national) else { return false }
        return t.types.contains { d in
            (d.lengths.map { $0.contains(national.count) } ?? true) && matchesEntirely(d.pattern, national)
        }
    }

    /// `getRegionCodeForNumber`: the only territory of the country calling code, else the first whose leading digits start
    /// the number or, without any, whose types match it.
    static func territory(code: Int, national: String) -> Territory? {
        guard let regions = metadata.regionsByCode[code] else { return nil }
        if regions.count == 1 { return regions[0] }
        for r in regions {
            if let leadingDigits = r.leadingDigits {
                if leading(leadingDigits, national) != nil { return r }
            } else if hasType(national, r) {
                return r
            }
        }
        return nil
    }

    /// The territory of a number that `isValidNumber` accepts, with its country calling code and national number; nil when
    /// [digits] (typed with a `+` before the first digit when [plus]) do not read as a valid number.
    struct Valid {
        var code: Int
        var national: String
        var territory: Territory
    }

    static func valid(_ digits: String, plus: Bool, region: String?) -> Valid? {
        guard let (code, national) = parse(digits, plus: plus, region: region),
              let t = territory(code: code, national: national), hasType(national, t)
        else { return nil }
        return Valid(code: code, national: national, territory: t)
    }

    static func isValid(_ digits: String, plus: Bool, region: String?) -> Bool { valid(digits, plus: plus, region: region) != nil }

    // MARK: - Formats (libphonenumber `formatNsn`)

    /// The national number drawn by the first format of [t] that fits it: with the national prefix rule for [international]
    /// false, in the international formats (those without `NA`) when the territory has any, else the national ones.
    static func formatted(_ national: String, code: Int, in t: Territory, international: Bool) -> String {
        let useIntl = international && t.formats.contains { !($0.intl ?? "").isEmpty }
        let list: [Format] = useIntl
            ? t.formats.filter { $0.intl != "NA" }.map { f in
                var g = f
                if let i = f.intl, !i.isEmpty { g.format = i }
                return g
            }
            : t.formats
        var out = national
        if let f = list.first(where: { fits($0, national) }) {
            var template = f.format
            // $FG is the first group the template draws, which is not always $1 (Argentina's mobiles start at $2).
            if !international, let rule = f.prefixRule, !rule.isEmpty,
               let at = template.range(of: "\\$\\d", options: .regularExpression) {
                let r = rule.replacingOccurrences(of: "$NP", with: t.nationalPrefix ?? "")
                    .replacingOccurrences(of: "$FG", with: String(template[at]))
                template.replaceSubrange(at, with: r)
            }
            if let regex = try? NSRegularExpression(pattern: "^(?:" + f.pattern + ")$") {
                out = regex.stringByReplacingMatches(
                    in: national, range: NSRange(national.startIndex..., in: national), withTemplate: template
                )
            }
        }
        return international ? "+\(code) \(out)" : out
    }

    private static func fits(_ f: Format, _ national: String) -> Bool {
        if let last = f.leading.last, leading(last, national) == nil { return false }
        return matchesEntirely(f.pattern, national)
    }
}
