import Foundation
import VettIDData

/// What a field's input lets through while the member types or pastes (VAULT-MESSAGING §10.7 field kinds; owner request
/// 2026-10-08: formats are enforced during entry). Characters a kind can never hold are dropped, a paste is normalised
/// (spaces out of a setup key, a decimal comma to a point), and what is still incomplete is left to the checks of
/// ``ItemChecks``, whose message shows under the field. Dates are typed as digits with the dashes drawn in
/// (``DateInput``). Mirrors vettid-android `FieldInput`.
public enum FieldInput {
    /// §10.7: `-?[0-9]{1,32}(\.[0-9]{1,32})?`.
    public static let maxNumberDigits = 32
    public static let maxPhone = 32
    public static let maxEmail = 254
    public static let maxURL = 2_048
    /// A base32 secret: 16–256 characters and up to 6 `=` of padding (§10.7).
    public static let maxOtpSecret = 256 + 6
    static let otpauth = "otpauth:"
    static let phoneSigns = Set(" +-().")

    /// Kinds whose value has a format the input enforces (and whose rule shows while it is incomplete).
    public static let formatted: Set<String> = [
        FieldKinds.number, FieldKinds.date, FieldKinds.email, FieldKinds.phone, FieldKinds.url, FieldKinds.otp,
    ]

    /// What an input of [kind] keeps of [typed] (the whole new text, typed or pasted). Dates go through ``DateInput``.
    public static func accept(_ kind: String, _ typed: String) -> String {
        switch kind {
        case FieldKinds.number: number(typed)
        case FieldKinds.phone: phone(typed)
        case FieldKinds.email: utf8Take(String(typed.filter { !$0.isWhitespace }), maxEmail)
        case FieldKinds.url: utf8Take(String(typed.filter { !$0.isWhitespace }), maxURL)
        case FieldKinds.otp: otp(typed)
        case FieldKinds.multiline, FieldKinds.password: typed
        default: typed.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }
    }

    /// A decimal (§10.7): digits, one leading minus and one point. A comma counts as the decimal point unless the text
    /// also has a point (then commas group thousands and go); spaces, underscores and apostrophes go; a point before any
    /// digit gets a 0 (".5" → "0.5").
    public static func number(_ typed: String) -> String {
        let s = String(typed.replacingOccurrences(of: "−", with: "-").filter { !$0.isWhitespace && $0 != "_" && $0 != "'" })
        let both = s.contains(".") && s.contains(",")
        let unified = both ? s.replacingOccurrences(of: ",", with: "") : s.replacingOccurrences(of: ",", with: ".")
        var out = ""
        var point = false
        var whole = 0
        var fraction = 0
        for c in unified {
            if c == "-", out.isEmpty {
                out.append(c)
            } else if c.isASCII, c.isNumber, !point, whole < maxNumberDigits {
                out.append(c)
                whole += 1
            } else if c.isASCII, c.isNumber, point, fraction < maxNumberDigits {
                out.append(c)
                fraction += 1
            } else if c == ".", !point {
                if whole == 0 {
                    out.append("0")
                    whole = 1
                }
                out.append(".")
                point = true
            }
        }
        return out
    }

    /// At most 32 digits, spaces and `+-().` (§10.7).
    public static func phone(_ typed: String) -> String {
        String(typed.filter { ($0.isASCII && $0.isNumber) || phoneSigns.contains($0) }.prefix(maxPhone))
    }

    /// A TOTP seed (§10.7): an `otpauth://` URI (the scheme in lower case, no white space), or a base32 secret in upper
    /// case with only its alphabet (A–Z, 2–7) and trailing `=`: the spaces and dashes a site shows a key with go. While the
    /// text could still become `otpauth:` it is kept as typed, in lower case.
    public static func otp(_ typed: String) -> String {
        let t = String(typed.filter { !$0.isWhitespace })
        let lower = t.lowercased()
        if lower.hasPrefix(otpauth) { return utf8Take(otpauth + t.dropFirst(otpauth.count), maxURL) }
        if !t.isEmpty, otpauth.hasPrefix(lower) { return lower }
        let secret = String(t.uppercased().filter { ("A"..."Z").contains($0) || ("2"..."7").contains($0) || $0 == "=" })
        // Padding only at the end: an `=` followed by more of the secret goes.
        let trimmed = secret.replacingOccurrences(of: "=+$", with: "", options: .regularExpression)
        let body = trimmed.replacingOccurrences(of: "=", with: "")
        return String((body + String(repeating: "=", count: secret.count - trimmed.count)).prefix(maxOtpSecret))
    }

    /// An address's country (§10.7): two letters, upper case.
    public static func country(_ typed: String) -> String {
        String(typed.filter { $0.isASCII && $0.isLetter }.uppercased().prefix(2))
    }

    /// The longest prefix of [s] of at most [max] UTF-8 bytes.
    public static func utf8Take(_ s: String, _ max: Int) -> String {
        var bytes = 0
        var out = ""
        for c in s.unicodeScalars {
            let n = String(c).utf8.count
            if bytes + n > max { break }
            bytes += n
            out.unicodeScalars.append(c)
        }
        return out
    }

    /// Whether [text] is not (yet) a value of [kind] (§10.7): its rule then shows under the field while typing.
    public static func incomplete(_ kind: String, _ text: String) -> Bool {
        formatted.contains(kind) && !text.isEmpty && ItemChecks.valueProblems(kind, .text(text)).contains(.valueInvalid)
    }
}

/// A `date` value (§10.7: `YYYY-MM-DD` or `YYYY-MM`, a valid calendar date), typed as digits: the input shows the digits
/// with the dashes drawn in, and the stored value is always the spec's format. A digit no date can continue with (month
/// 13, day 32, 30 February) is refused; a month-and-year field (a card's expiry) stops at the month. Mirrors vettid-android
/// `DateInput`.
public enum DateInput {
    static let year = 4
    static let month = 6
    static let day = 8

    /// The digits of a stored value, as the input holds them.
    public static func digits(_ stored: String) -> String { String(stored.filter { $0.isASCII && $0.isNumber }) }

    /// Digits in the spec's format: `YYYY`, `YYYY-M`, `YYYY-MM`, `YYYY-MM-D`, `YYYY-MM-DD`.
    public static func format(_ d: String) -> String {
        var out = ""
        for (i, c) in d.enumerated() {
            if i == year || i == month { out.append("-") }
            out.append(c)
        }
        return out
    }

    /// The stored value for what the input now holds ([typed]: its digits count, so a pasted `2031-04-30` or `2031/04/30`
    /// works), or nil when no date can begin so and the change is refused. A deletion (fewer digits than [old] held)
    /// always goes through, so a digit in the middle can be taken out and typed again.
    public static func accept(old: String, typed: String, monthOnly: Bool) -> String? {
        let d = String(digits(typed).prefix(monthOnly ? month : day))
        return possible(d) || d.count < digits(old).count ? format(d) : nil
    }

    /// Whether some valid date begins with the digits [d].
    public static func possible(_ d: String) -> Bool {
        let b = Array(d.utf8).map { Int($0) - 48 }
        if b.count > year, b[year] > 1 { return false }
        if b.count >= month, !(1...12).contains(b[year] * 10 + b[year + 1]) { return false }
        if b.count > month, b[month] > 3 { return false }
        if b.count >= day { return isDay(format(String(d.prefix(day)))) }
        return true
    }

    /// Whether [s] is a valid `YYYY-MM-DD`.
    static func isDay(_ s: String) -> Bool { s.utf8.count == 10 && ItemChecks.valueProblems(FieldKinds.date, .text(s)).isEmpty }

    /// Whether a stored value is a month and year (`YYYY-MM`).
    public static func isMonth(_ stored: String) -> Bool {
        stored.utf8.count == 7 && ItemChecks.valueProblems(FieldKinds.date, .text(stored)).isEmpty
    }

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }

    /// The stored day (or a month's first day) for the calendar to open on, at noon UTC; nil for none.
    public static func toPicker(_ stored: String) -> Date? {
        let p = stored.split(separator: "-").compactMap { Int($0) }
        guard (2...3).contains(p.count), isDay(stored) || isMonth(stored) else { return nil }
        return utc.date(from: DateComponents(year: p[0], month: p[1], day: p.count == 3 ? p[2] : 1, hour: 12))
    }

    /// A day the calendar returned as the spec's `YYYY-MM-DD` (the day as the member saw it, in this phone's zone).
    public static func fromPicker(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    /// A month and year as the spec's `YYYY-MM`.
    public static func month(year: Int, month: Int) -> String { String(format: "%04d-%02d", year, month) }

    /// The year and month of a stored value (a day's or a month's), else nil.
    public static func yearMonth(_ stored: String) -> (year: Int, month: Int)? {
        guard isDay(stored) || isMonth(stored) else { return nil }
        let p = stored.split(separator: "-").compactMap { Int($0) }
        return (p[0], p[1])
    }
}

/// A `phone` value (§10.7 allows at most 32 digits, spaces and `+-().`). vettid-android draws libphonenumber's as-you-type
/// format over the digits, stores a number that parses in international format and shows it for the viewer's region; the
/// iPhone app has no phone-number library, so a number is kept and shown as typed, within §10.7's characters (chosen; not
/// in the spec: a library such as libphonenumber would be a new dependency, asked of the owner). Mirrors the parts of
/// vettid-android `PhoneInput` that need no library.
public enum PhoneInput {
    /// What is saved for [text]: as typed, within §10.7's characters.
    public static func stored(_ text: String) -> String { FieldInput.phone(text) }

    /// A stored number as shown: as stored.
    public static func display(_ stored: String) -> String { stored }
}
