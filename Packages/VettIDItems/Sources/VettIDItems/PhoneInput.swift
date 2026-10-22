import Foundation
import PhoneNumberKit

/// A `phone` value (VAULT-MESSAGING §10.7 "Phone values", 0.55.0; IOS-PLAN §4.8). What is stored is one form whatever the
/// library formats: an extension is never stored; a number that is a possible number (libphonenumber's
/// `isPossibleNumberWithReason` is `IS_POSSIBLE`) is stored in E.164 (`+442079460958`), anything else as its dialable
/// characters only (a leading `+` if typed, at most 15 digits, `""` with no digit), with the hint "Check this number" and
/// never a block. The national, international and as-you-type formats only draw what is shown. The region of a number typed
/// without a `+` is the device's locale region (``deviceRegion``); with none, such a number is not read as a phone
/// number. Mirrors vettid-android `PhoneInput`; the library is PhoneNumberKit (libphonenumber's metadata and formats).
public enum PhoneInput {
    /// Every writer keeps the edit text of a phone field, the extension marker text included, to this many characters
    /// (VAULT-MESSAGING 0.55.4 §10.7 "Phone values" 3), so the fallback form always satisfies the table. No digit is cut
    /// before the number is read.
    public static let maxEditLength = 32

    /// The locale's region (`Locale.current.region`): iOS has no reliable network or SIM country; nil when the locale has
    /// none or the library does not know it.
    public static var deviceRegion: String? {
        guard let id = Locale.current.region?.identifier, PhoneRules.metadata.byID[id.uppercased()] != nil else { return nil }
        return id.uppercased()
    }

    // MARK: - Extensions

    /// An extension marker: `x`, `ext` (with an optional `.`), `;ext=`, `#` or `,`, in any case, found in the text as typed
    /// or pasted, before any character is filtered.
    private static let marker = try? NSRegularExpression(pattern: ";ext=|ext\\.?|x|#|,", options: .caseInsensitive)

    /// Where the extension marker starts in [text], if there is one.
    static func markerIndex(_ text: String) -> String.Index? {
        let matches = marker?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        for m in matches {
            // Only where at least one digit comes before it: "Fax: +44 20 7946 0958" and "Text 555 0100" hold no extension.
            guard let at = Range(m.range, in: text)?.lowerBound else { continue }
            if text[..<at].contains(where: { $0.isASCII && $0.isNumber }) { return at }
        }
        return nil
    }

    /// Whether [text] holds an extension marker: the note "Extensions aren't saved; add it to the item's notes." shows.
    public static func hasExtension(_ text: String) -> Bool { markerIndex(text) != nil }

    /// The number of [text] and its extension (the marker and what follows).
    private static func split(_ text: String) -> (number: String, tail: String) {
        guard let i = markerIndex(text) else { return (text, "") }
        return (String(text[..<i]), String(text[i...]))
    }

    // MARK: - The dialable characters

    /// A `+` that comes before the first digit (VAULT-MESSAGING 0.55.1) and every ASCII digit of [number].
    private static func dialable(_ number: String) -> (plus: Bool, digits: String) {
        var plus = false
        var seen = false
        var digits = ""
        for c in number {
            if c == "+" {
                if !seen { plus = true }
                seen = true
            } else if c.isASCII, c.isNumber {
                digits.append(c)
                seen = true
            }
        }
        return (plus, digits)
    }

    /// The dialable characters of [text] without its extension: a leading `+` if typed, then all its digits;
    /// `""` with no digit (the form for what is not a possible number).
    public static func raw(_ text: String) -> String {
        let d = dialable(split(text).number)
        return d.digits.isEmpty ? "" : (d.plus ? "+" : "") + d.digits
    }

    /// What the edit text keeps of [typed] (a typed or pasted text, whole): the number as ``raw(_:)`` has it (a bare `+` kept
    /// so it can be followed by digits), and an extension marker with what follows, as typed, until the field is saved.
    public static func edit(_ typed: String) -> String {
        let (number, tail) = split(typed)
        let d = dialable(number)
        let head = (d.plus ? "+" : "") + d.digits
        return String((head + tail.filter { !$0.isNewline }).prefix(maxEditLength))
    }

    // MARK: - What is stored

    /// What is saved for [text] (the edit text): the E.164 form of a possible number in [region] (without a `+`), else
    /// ``raw(_:)``. The extension is dropped. Stored again, a stored value does not change.
    public static func stored(_ text: String, region: String? = deviceRegion) -> String {
        let d = dialable(split(text).number)
        guard !d.digits.isEmpty else { return "" }
        // No digit is cut (0.55.4): the library decides, and a number it does not find possible keeps all its digits.
        return PhoneRules.e164(d.digits, plus: d.plus, region: region) ?? (d.plus ? "+" : "") + d.digits
    }

    /// Whether [text] has digits but is not a valid number (libphonenumber's `isValidNumber`; VAULT-MESSAGING 0.55.4 §10.7
    /// "Phone values" 3): "Check this number" shows whether the value is stored as E.164 or as dialable characters, and
    /// never blocks.
    public static func doubtful(_ text: String, region: String? = deviceRegion) -> Bool {
        let d = dialable(split(text).number)
        guard !d.digits.isEmpty else { return false }
        return !PhoneRules.isValid(d.digits, plus: d.plus, region: region)
    }

    // MARK: - What is shown

    /// A stored number as shown: in national format for a number of [region], else in international format; what is not a
    /// valid number stays as stored (as vettid-android). Display only.
    public static func display(_ stored: String, region: String? = deviceRegion) -> String {
        guard !stored.isEmpty else { return stored }
        let d = dialable(stored)
        guard let v = PhoneRules.valid(d.digits, plus: d.plus, region: region) else { return stored }
        let home = region != nil && v.territory.id == region?.uppercased()
        // Formats come from the main territory of the country calling code, as libphonenumber's `format` takes them.
        let formats = PhoneRules.metadata.mainByCode[v.code] ?? v.territory
        return PhoneRules.formatted(v.national, code: v.code, in: formats, international: !home)
    }

    /// The edit text drawn as the member types: the number in the as-you-type format (for [region], or by its country code
    /// after a `+`), then the extension as typed. Display only: the edit text is ``edit(_:)``.
    public static func mask(_ edit: String, region: String? = deviceRegion) -> String {
        let (number, tail) = split(edit)
        let d = dialable(number)
        let raw = (d.plus ? "+" : "") + d.digits
        var drawn = d.digits.isEmpty || (region == nil && !d.plus) ? raw : engine.partial(raw, region: region)
        if raw.hasPrefix("+1") {
            drawn = internationalNanp(drawn)
        } else if !d.plus, d.digits.hasPrefix("1"), let r = region, PhoneRules.metadata.byID[r.uppercased()]?.countryCode == 1 {
            // A North American number dialled with its trunk 1: `1 650-253-0000`.
            let rest = String(d.digits.dropFirst())
            drawn = rest.isEmpty ? "1" : "1 " + internationalNanp(engine.partial("+1" + rest, region: region)).dropFirst(3)
        }
        return tail.isEmpty ? drawn : drawn + " " + tail
    }

    /// libphonenumber draws a North American number with its country code as `+1 650-253-0000`, PhoneNumberKit's partial
    /// format as `+1 (650) 253-0000`.
    static func internationalNanp(_ drawn: String) -> String {
        guard drawn.hasPrefix("+1 (") else { return drawn }
        var s = String(drawn.dropFirst(4))
        if let close = s.firstIndex(of: ")") {
            let rest = s[s.index(after: close)...].drop(while: { $0 == " " })
            s = String(s[..<close]) + (rest.isEmpty ? "" : "-" + rest)
        }
        return "+1 " + s
    }

    /// The text to read when [typed] replaced [shown] (the drawn number) and only separators (`(`, `)`, `-`, spaces) are gone:
    /// the digit before them goes too, or a backspace over a drawn separator would delete nothing. Any other change is
    /// [typed] as it is. Cursor position in the middle of a number needs a check on the iPhone.
    public static func afterDeletion(shown: String, typed: String) -> String {
        guard typed.count < shown.count, !hasExtension(shown) else { return typed }
        let s = Array(shown), t = Array(typed)
        var p = 0
        while p < t.count, s[p] == t[p] { p += 1 }
        let removed = s.count - t.count
        guard p + removed <= s.count, Array(s[(p + removed)...]) == Array(t[p...]) else { return typed }
        let isDial = { (c: Character) in (c.isASCII && c.isNumber) || c == "+" }
        guard s[p..<(p + removed)].allSatisfy({ !isDial($0) }) else { return typed }
        var head = Array(t[..<p])
        guard let i = head.lastIndex(where: isDial) else { return typed }
        head.remove(at: i)
        return String(head) + String(t[p...])
    }

    private static let engine = PhoneEngine()
}

/// PhoneNumberKit's as-you-type formatter, behind a lock (its utility keeps caches and is not documented as thread-safe).
private final class PhoneEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let utility = PhoneNumberUtility()

    func partial(_ raw: String, region: String?) -> String {
        lock.lock()
        defer { lock.unlock() }
        let f = PartialFormatter(utility: utility, defaultRegion: region ?? "US", withPrefix: true)
        return f.formatPartial(raw)
    }
}
