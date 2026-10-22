import Foundation
import PhoneNumberKit

/// libphonenumber's "possible number" rule (`isPossibleNumberWithReason` is `IS_POSSIBLE`, not `IS_POSSIBLE_LOCAL_ONLY`) on
/// the metadata PhoneNumberKit bundles (it is libphonenumber's metadata). PhoneNumberKit parses only what it can type as a
/// valid number and has no possible-number check, so the lenient parse of libphonenumber's `parseHelper` (the country code,
/// the international prefix, the national prefix) and its `testNumberLength` are written here over that metadata (chosen;
/// not in the spec: IOS-PLAN §4.8 leaves the port to the app, which must give Android's results). The general
/// description's lengths are the union of the lengths of every number type of the territory, as libphonenumber builds them
/// (libphonenumber's builder leaves `noInternationalDialling` out of that union and this one includes it; no territory
/// differs today).
enum PhoneRules {
    /// libphonenumber's `ValidationResult`.
    enum Length { case possible, localOnly, tooShort, tooLong, invalidLength }

    /// `MIN_LENGTH_FOR_NSN` and `MAX_LENGTH_FOR_NSN`.
    static let minNational = 2
    static let maxNational = 17

    struct Territory: Sendable {
        var id: String
        var countryCode: Int
        var main: Bool
        var internationalPrefix: String?
        var nationalPrefixForParsing: String?
        var nationalPrefixTransformRule: String?
        var generalPattern: String?
        var national: [Int]
        var localOnly: Set<Int>
    }

    struct Metadata: Sendable {
        var byID: [String: Territory] = [:]
        /// The main territory of a country calling code (libphonenumber's `getRegionCodeForCountryCode`).
        var mainByCode: [Int: Territory] = [:]
    }

    private static let types = [
        "fixedLine", "mobile", "pager", "personalNumber", "premiumRate", "sharedCost", "tollFree", "voicemail", "voip", "uan",
        "noInternationalDialling",
    ]

    static let metadata: Metadata = load()

    private static func load() -> Metadata {
        guard let data = try? PhoneNumberUtility.defaultMetadataCallback(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let top = root["phoneNumberMetadata"] as? [String: Any],
              let wrapper = top["territories"] as? [String: Any],
              let list = wrapper["territory"] as? [[String: Any]]
        else { return Metadata() }
        var m = Metadata()
        for o in list {
            guard let id = o["id"] as? String, let cc = (o["countryCode"] as? String).flatMap({ Int($0) }) else { continue }
            var national = Set<Int>()
            var local = Set<Int>()
            for t in types {
                guard let desc = o[t] as? [String: Any], let l = desc["possibleLengths"] as? [String: Any] else { continue }
                national.formUnion(lengths(l["national"] as? String))
                local.formUnion(lengths(l["localOnly"] as? String))
            }
            let general = (o["generalDesc"] as? [String: Any])?["nationalNumberPattern"] as? String
            let t = Territory(
                id: id, countryCode: cc, main: (o["mainCountryForCode"] as? String) == "true",
                internationalPrefix: o["internationalPrefix"] as? String,
                nationalPrefixForParsing: (o["nationalPrefixForParsing"] as? String) ?? (o["nationalPrefix"] as? String),
                nationalPrefixTransformRule: o["nationalPrefixTransformRule"] as? String, generalPattern: general,
                national: national.sorted(), localOnly: local.subtracting(national)
            )
            m.byID[id] = t
            if t.main || m.mainByCode[cc] == nil { m.mainByCode[cc] = t }
        }
        // A territory flagged as the main one wins over the first listed.
        for t in m.byID.values where t.main { m.mainByCode[t.countryCode] = t }
        return m
    }

    /// `"6,[8-10]"` as 6, 8, 9, 10.
    static func lengths(_ s: String?) -> Set<Int> {
        var out = Set<Int>()
        for part in (s ?? "").split(separator: ",") {
            let p = part.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            let ends = p.split(separator: "-").compactMap { Int($0) }
            if ends.count == 2, ends[0] <= ends[1] {
                out.formUnion(ends[0]...ends[1])
            } else if ends.count == 1, !p.contains("-") {
                out.insert(ends[0])
            }
        }
        return out
    }

    /// libphonenumber's `testNumberLength` on the general description.
    static func length(_ national: String, in t: Territory) -> Length {
        guard let first = t.national.first, let last = t.national.last else { return .invalidLength }
        let n = national.count
        if t.localOnly.contains(n) { return .localOnly }
        if first == n { return .possible }
        if first > n { return .tooShort }
        if last < n { return .tooLong }
        return t.national.contains(n) ? .possible : .invalidLength
    }

    // MARK: - Regular expressions

    private static func matchesEntirely(_ pattern: String?, _ s: String) -> Bool {
        guard let pattern, let r = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
        return r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The match of [pattern] at the start of [s] (`lookingAt`).
    private static func leading(_ pattern: String, _ s: String) -> NSTextCheckingResult? {
        guard let r = try? NSRegularExpression(pattern: "^(?:" + pattern + ")") else { return nil }
        return r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    // MARK: - Parsing (libphonenumber `parseHelper`, without validation)

    /// The country calling code at the start of [digits] and the rest (`extractCountryCode`); nil when none.
    private static func countryCode(_ digits: String) -> (Int, String)? {
        guard let first = digits.first, first != "0" else { return nil }
        for i in 1...min(3, digits.count) {
            if let code = Int(digits.prefix(i)), metadata.mainByCode[code] != nil { return (code, String(digits.dropFirst(i))) }
        }
        return nil
    }

    /// `maybeStripNationalPrefixAndCarrierCode`.
    private static func strippingNationalPrefix(_ number: String, _ t: Territory) -> String {
        guard !number.isEmpty, let prefix = t.nationalPrefixForParsing, let m = leading(prefix, number) else { return number }
        let ns = number as NSString
        let viable = matchesEntirely(t.generalPattern, number)
        let lastGroup = m.numberOfRanges - 1
        let hasGroup = lastGroup > 0 && m.range(at: lastGroup).location != NSNotFound
        if let rule = t.nationalPrefixTransformRule, !rule.isEmpty, hasGroup {
            let regex = try? NSRegularExpression(pattern: "^(?:" + prefix + ")")
            let transformed = regex?.stringByReplacingMatches(
                in: number, range: NSRange(location: 0, length: ns.length), withTemplate: rule
            ) ?? number
            return viable && !matchesEntirely(t.generalPattern, transformed) ? number : transformed
        }
        let rest = ns.substring(from: m.range.length)
        return viable && !matchesEntirely(t.generalPattern, rest) ? number : rest
    }

    /// How the start of the digits is read: a country calling code and the rest, no code (the region's own), or an error.
    private enum Lead {
        case code(Int, String)
        case none
        case failed
    }

    private static func lead(_ digits: String, plus: Bool, home: Territory?) -> Lead {
        if plus {
            guard digits.count > minNational, let c = countryCode(digits) else { return .failed }
            return .code(c.0, c.1)
        }
        guard let home else { return .failed }
        // An international call prefix (not followed by a 0) is the same as a `+`.
        if let idd = home.internationalPrefix, let m = leading(idd, digits), m.range.length > 0 {
            let rest = String(digits.dropFirst(m.range.length))
            if rest.first != "0" {
                guard rest.count > minNational, let c = countryCode(rest) else { return .failed }
                return .code(c.0, c.1)
            }
        }
        return defaultRegionCode(digits, home).map { .code($0.0, $0.1) } ?? .none
    }

    /// The country calling code and the national significant number [digits] make, typed with a leading `+` ([plus]) or
    /// for [region] (an ISO 3166-1 alpha-2 code, or nil), as libphonenumber's lenient parse reads them; nil when it throws.
    static func parse(_ digits: String, plus: Bool, region: String?) -> (code: Int, national: String)? {
        let home = region.flatMap { metadata.byID[$0.uppercased()] }
        let code: Int
        var national: String
        let t: Territory
        switch lead(digits, plus: plus, home: home) {
        case .failed: return nil
        case .code(let c, let rest):
            guard let main = metadata.mainByCode[c] else { return nil }
            code = c
            national = rest
            // A country code read from the region's own default keeps the region's metadata.
            t = !plus && home?.countryCode == c ? home ?? main : main
        case .none:
            guard let home else { return nil }
            code = home.countryCode
            national = digits
            t = home
        }
        guard national.count >= minNational else { return nil }
        let stripped = strippingNationalPrefix(national, t)
        switch length(stripped, in: t) {
        case .tooShort, .localOnly, .invalidLength: break
        case .possible, .tooLong: national = stripped
        }
        guard (minNational...maxNational).contains(national.count) else { return nil }
        return (code, national)
    }

    /// `maybeExtractCountryCode` without a `+`: the digits start with the region's own country code and the rest is the
    /// better reading.
    private static func defaultRegionCode(_ digits: String, _ home: Territory) -> (Int, String)? {
        let code = String(home.countryCode)
        guard digits.hasPrefix(code) else { return nil }
        let rest = String(digits.dropFirst(code.count))
        let strippedRest = strippingNationalPrefix(rest, home)
        let better = (!matchesEntirely(home.generalPattern, digits) && matchesEntirely(home.generalPattern, strippedRest))
            || length(digits, in: home) == .tooLong
        return better ? (home.countryCode, strippedRest) : nil
    }

    /// The E.164 form of [digits] when libphonenumber says it is a possible number (`IS_POSSIBLE`), else nil.
    static func e164(_ digits: String, plus: Bool, region: String?) -> String? {
        guard let (code, national) = parse(digits, plus: plus, region: region), let t = metadata.mainByCode[code],
              length(national, in: t) == .possible
        else { return nil }
        return "+\(code)\(national)"
    }
}
