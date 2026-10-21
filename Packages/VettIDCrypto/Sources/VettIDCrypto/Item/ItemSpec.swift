import Foundation

/// The shape of items (VAULT-MESSAGING §10.7, §10.8; VAULT-ITEMS): field kinds and value checks, tag normalisation and the
/// canonical value encoding, ported from the Go reference's `features/itemspec` so that the app validates before sending
/// what the vault would refuse, and encodes byte for byte what it would. The vault remains the authority. Mirrors
/// vettid-android `ItemSpec`.
public enum ItemSpec {
    public static let data = "data"
    public static let secret = "secret"
    public static let critical = "critical"

    public static let kindText = "text"
    public static let kindMultiline = "multiline"
    public static let kindNumber = "number"
    public static let kindDate = "date"
    public static let kindEmail = "email"
    public static let kindPhone = "phone"
    public static let kindURL = "url"
    public static let kindPassword = "password"
    public static let kindOTP = "otp"
    public static let kindAddress = "address"
    /// Reserved (files later) and refused.
    public static let kindFile = "file"

    public static let maxName = 128
    public static let maxNotes = 16_384
    public static let maxFields = 64
    public static let maxLabel = 64
    public static let maxValue = 16_384
    public static let maxItemBytes = 65_536
    public static let maxCriticalBytes = 12_288
    public static let maxTags = 16
    public static let maxTagLength = 32
    public static let maxAddressPart = 256
    public static let maxURL = 2_048
    public static let maxEmail = 254
    public static let maxPhone = 32
    public static let profileTag = "@profile"

    public static let recommendedCategories = [
        "identity_document", "login", "payment_card", "bank_account", "medical", "insurance", "vehicle", "contact", "note",
        "crypto_wallet", "other",
    ]

    public static let kinds: Set<String> = [
        kindText, kindMultiline, kindNumber, kindDate, kindEmail, kindPhone, kindURL, kindPassword, kindOTP, kindAddress,
    ]

    /// The members of an `address`, in the order the vault encodes them.
    public static let addressParts = ["street", "street2", "city", "region", "postal_code", "country"]

    private static func len(_ s: String) -> Int { s.utf8.count }

    private static func isLower(_ c: UInt8) -> Bool { c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z") }
    private static func isUpper(_ c: UInt8) -> Bool { c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") }
    private static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

    /// `[a-z][a-z0-9_]{0,31}`.
    public static func isValidCategory(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...32).contains(b.count), isLower(b[0]) else { return false }
        return b.allSatisfy { isLower($0) || isDigit($0) || $0 == UInt8(ascii: "_") }
    }

    /// `[a-z0-9_.-]{1,64}`.
    public static func isValidTemplate(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return (1...64).contains(b.count) && b.allSatisfy { isLower($0) || isDigit($0) || "_.-".utf8.contains($0) }
    }

    public static func isValidSensitivity(_ s: String) -> Bool { s == data || s == secret || s == critical }

    /// `[A-Za-z0-9_-]{1,32}`.
    public static func isValidFieldID(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return (1...32).contains(b.count) && b.allSatisfy { isLower($0) || isUpper($0) || isDigit($0) || "_-".utf8.contains($0) }
    }

    public static func isValidKind(_ s: String) -> Bool { kinds.contains(s) }

    /// No control characters (U+0000–U+001F, U+007F), except line feed and tab when [multi]. (A Swift string holds only
    /// valid scalars, so the unpaired surrogates the Kotlin port refuses cannot occur.)
    public static func isCleanText(_ s: String, multi: Bool) -> Bool {
        s.unicodeScalars.allSatisfy { c in
            let control = c.value < 0x20 || c.value == 0x7F
            return !control || (multi && (c == "\n" || c == "\t"))
        }
    }

    public static func isValidName(_ s: String) -> Bool { !s.isEmpty && len(s) <= maxName && isCleanText(s, multi: false) }

    public static func isValidNotes(_ s: String) -> Bool { len(s) <= maxNotes && isCleanText(s, multi: true) }

    public static func isValidLabel(_ s: String) -> Bool { !s.isEmpty && len(s) <= maxLabel && isCleanText(s, multi: false) }

    /// Checks a string value of [kind] (§10.7); every kind accepts "".
    public static func isValidStringValue(_ kind: String, _ s: String) -> Bool { // swiftlint:disable:this cyclomatic_complexity
        guard len(s) <= maxValue else { return false }
        if kind == kindMultiline || kind == kindPassword { return isCleanText(s, multi: true) }
        guard isCleanText(s, multi: false) else { return false }
        if s.isEmpty { return kinds.contains(kind) }
        switch kind {
        case kindText: return true
        case kindNumber: return isValidNumber(s)
        case kindDate: return isValidDate(s)
        case kindEmail: return isValidEmail(s)
        case kindPhone: return isValidPhone(s)
        case kindURL: return isValidURL(s)
        case kindOTP: return isValidOTP(s)
        default: return false
        }
    }

    /// `-?[0-9]{1,32}(\.[0-9]{1,32})?`.
    static func isValidNumber(_ s: String) -> Bool {
        var b = Substring(s)
        if b.first == "-" { b = b.dropFirst() }
        let parts = b.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let digits = { (p: Substring) in (1...32).contains(p.utf8.count) && p.utf8.allSatisfy(isDigit) }
        return parts.count <= 2 && parts.allSatisfy(digits)
    }

    /// `YYYY-MM-DD` or `YYYY-MM`, a valid date of the proleptic Gregorian calendar (Go's `time.Parse` and `Format` give the
    /// same text back).
    static func isValidDate(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 10 || b.count == 7, b[4] == UInt8(ascii: "-") else { return false }
        func num(_ r: Range<Int>) -> Int? {
            let p = b[r]
            guard p.allSatisfy(isDigit) else { return nil }
            return p.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        }
        guard let year = num(0..<4), let month = num(5..<7), (1...12).contains(month) else { return false }
        if b.count == 7 { return true }
        guard b[7] == UInt8(ascii: "-"), let day = num(8..<10) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return (1...days).contains(day)
    }

    private static func noSpace(_ s: String) -> Bool { !s.unicodeScalars.contains { " \t\n\r".unicodeScalars.contains($0) } }

    static func isValidEmail(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count <= maxEmail, noSpace(s), b.count(where: { $0 == UInt8(ascii: "@") }) == 1,
              let at = b.firstIndex(of: UInt8(ascii: "@")) else { return false }
        return at > 0 && at < b.count - 1
    }

    static func isValidPhone(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count <= maxPhone && b.allSatisfy { isDigit($0) || " +-().".utf8.contains($0) } && b.contains(where: isDigit)
    }

    /// An absolute URI with a scheme, at most 2,048 bytes, no white space: what Go's `url.Parse` (Go 1.26, the vault's)
    /// accepts with a scheme (`u.Scheme != "" && u.IsAbs()`). As Go: no control character; a scheme
    /// `[A-Za-z][A-Za-z0-9+.-]*` before the first `:`; after it, an opaque part (not starting with `/`) and the query are
    /// not checked; the path and the fragment take `%` only before two hex digits; an authority's userinfo is of Go's
    /// `validUserinfo` characters; its host is of the characters Go allows in a host (`<`, `>` and `"` among them) with `%`
    /// escapes only of non-ASCII bytes or `%25`, or a bracketed IPv6 address (no IPv4) with an optional zone after `%25`;
    /// a port is digits, after the first `:` of an `http` or `https` host and after the last of any other. (Chosen; not in
    /// the spec: the bracketed address is checked with `inet_pton`, not Go's `netip.ParseAddr`, which may differ on
    /// unusual forms.)
    static func isValidURL(_ s: String) -> Bool {
        guard len(s) <= maxURL, noSpace(s), isCleanText(s, multi: false) else { return false }
        let all = Array(s.utf8)
        let hash = all.firstIndex(of: UInt8(ascii: "#")) ?? all.count
        guard hash == all.count || escapesValid(all[(hash + 1)...]) else { return false }
        let b = all[..<hash]
        guard let colon = b.firstIndex(of: UInt8(ascii: ":")), colon > 0, isLower(b[0]) || isUpper(b[0]) else { return false }
        guard b[1..<colon].allSatisfy({ isLower($0) || isUpper($0) || isDigit($0) || "+.-".utf8.contains($0) }) else { return false }
        let scheme = (String(bytes: b[..<colon], encoding: .utf8) ?? "").lowercased()
        var rest = b[(colon + 1)...]
        if let q = rest.firstIndex(of: UInt8(ascii: "?")) { rest = rest[..<q] }
        guard rest.first == UInt8(ascii: "/") else { return true }
        guard rest.starts(with: "//".utf8) else { return escapesValid(rest) }
        let authority = rest.dropFirst(2)
        let slash = authority.firstIndex(of: UInt8(ascii: "/")) ?? authority.endIndex
        return authorityValid(authority[..<slash], scheme: scheme) && escapesValid(authority[slash...])
    }

    /// Go's `parseAuthority`: the host after the last `@`, the userinfo before it.
    private static func authorityValid(_ a: ArraySlice<UInt8>, scheme: String) -> Bool {
        guard let at = a.lastIndex(of: UInt8(ascii: "@")) else { return hostValid(a, scheme: scheme) }
        let userinfo = a[..<at]
        let allowed = { (c: UInt8) in isLower(c) || isUpper(c) || isDigit(c) || "-._:~!$&'()*+,;=%@".utf8.contains(c) }
        return hostValid(a[(at + 1)...], scheme: scheme) && userinfo.allSatisfy(allowed) && escapesValid(userinfo)
    }

    /// Go 1.26's `parseHost`: `[` only at the start, opening an IPv6 literal (with an optional zone) and an optional port;
    /// otherwise a name with an optional port, after the first `:` for `http` and `https`, after the last for others.
    private static func hostValid(_ h: ArraySlice<UInt8>, scheme: String) -> Bool {
        let port = { (p: ArraySlice<UInt8>) in p.isEmpty || (p.first == UInt8(ascii: ":") && p.dropFirst().allSatisfy(isDigit)) }
        if let open = h.lastIndex(of: UInt8(ascii: "[")), open != h.startIndex { return false }
        guard h.first == UInt8(ascii: "[") else {
            let web = scheme == "http" || scheme == "https"
            let c = web ? h.firstIndex(of: UInt8(ascii: ":")) : h.lastIndex(of: UInt8(ascii: ":"))
            if let c, !port(h[c...]) { return false }
            return hostEscapes(h, zone: false)
        }
        guard let close = h.lastIndex(of: UInt8(ascii: "]")), port(h[(close + 1)...]) else { return false }
        let name = h[(h.startIndex + 1)..<close]
        let z = (name.startIndex..<name.endIndex).first { name[$0...].starts(with: "%25".utf8) }
        let address = z.map { name[..<$0] } ?? name
        if let z {
            // A zone is not empty once unescaped (`netip.ParseAddr`).
            guard name.endIndex - z > 3, hostEscapes(name[z...], zone: true) else { return false }
        }
        return isIPv6(address)
    }

    /// An IPv6 address, written without escapes (Go's `netip.ParseAddr`, refusing IPv4; an IPv4-mapped address is IPv6).
    private static func isIPv6(_ a: ArraySlice<UInt8>) -> Bool {
        guard !a.contains(UInt8(ascii: "%")) else { return false }
        var out = in6_addr()
        guard let text = String(bytes: a, encoding: .utf8) else { return false }
        return text.withCString { inet_pton(AF_INET6, $0, &out) } == 1
    }

    /// Whether Go's `shouldEscape(c, encodeHost)` is false: the characters a host may hold as they are.
    private static func hostChar(_ c: UInt8) -> Bool {
        isLower(c) || isUpper(c) || isDigit(c) || "!$&'()*+,;=:[]<>\"-_.~".utf8.contains(c)
    }

    /// Go's `unescape` in the host and zone modes: ASCII only of the host's characters; `%` before two hex digits, in a
    /// host only `%25` or a non-ASCII byte, in a zone `%25`, a space or an ASCII character a host takes.
    private static func hostEscapes(_ h: ArraySlice<UInt8>, zone: Bool) -> Bool {
        var i = h.startIndex
        while i < h.endIndex {
            let c = h[i]
            guard c == UInt8(ascii: "%") else {
                guard c >= 0x80 || hostChar(c) else { return false }
                i += 1
                continue
            }
            guard i + 2 < h.endIndex, let hi = hexValue(h[i + 1]), let lo = hexValue(h[i + 2]) else { return false }
            let v = hi << 4 | lo
            let escapedPercent = v == 0x25
            if zone {
                guard escapedPercent || v == 0x20 || (v < 0x80 && hostChar(v)) else { return false }
            } else {
                guard escapedPercent || hi >= 8 else { return false }
            }
            i += 3
        }
        return true
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        if isDigit(c) { return c - UInt8(ascii: "0") }
        if (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(c) { return c - UInt8(ascii: "a") + 10 }
        if (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(c) { return c - UInt8(ascii: "A") + 10 }
        return nil
    }

    /// `%` only before two hex digits (Go's `unescape` of a path, a fragment or a userinfo).
    private static func escapesValid(_ b: ArraySlice<UInt8>) -> Bool {
        var i = b.startIndex
        while i < b.endIndex {
            if b[i] == UInt8(ascii: "%") {
                guard i + 2 < b.endIndex, hexValue(b[i + 1]) != nil, hexValue(b[i + 2]) != nil else { return false }
                i += 3
            } else {
                i += 1
            }
        }
        return true
    }

    /// An `otpauth://` URI, or a base32 secret: the RFC 4648 alphabet, case-insensitive, 16–256 characters, at most 6 `=`.
    static func isValidOTP(_ s: String) -> Bool {
        if s.hasPrefix("otpauth://") { return isValidURL(s) }
        let b = Array(s.utf8)
        var end = b.count
        while end > 0, b[end - 1] == UInt8(ascii: "=") { end -= 1 }
        guard b.count - end <= 6, (16...256).contains(end) else { return false }
        return b[..<end].allSatisfy { isLower($0) || isUpper($0) || ($0 >= UInt8(ascii: "2") && $0 <= UInt8(ascii: "7")) }
    }

    /// Checks a field value of [kind] and returns its canonical JSON: a string, or an address object with its non-empty
    /// members in fixed order.
    public static func canonicalValue(_ kind: String, _ v: JsonValue) throws -> String {
        guard kind == kindAddress else {
            let s = try v.asString()
            guard isValidStringValue(kind, s) else { throw CryptoError.format("value") }
            return JsonBuilder.quote(s)
        }
        let o = try v.asObject()
        guard o.members.allSatisfy({ addressParts.contains($0.name) }) else { throw CryptoError.format("address") }
        let b = JsonBuilder()
        for k in addressParts {
            guard let s = try o.optString(k) else { continue }
            guard len(s) <= maxAddressPart, isCleanText(s, multi: false) else { throw CryptoError.format("address") }
            if k == "country", !s.isEmpty, !isCountryCode(s) { throw CryptoError.format("address country") }
            if !s.isEmpty { b.string(k, s) }
        }
        return b.build()
    }

    /// An ISO 3166-1 alpha-2 code in upper case: `[A-Z]{2}`.
    public static func isCountryCode(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return b.count == 2 && b.allSatisfy(isUpper)
    }

    /// Normalises a tag (§10.8): spaces trimmed, A–Z lowered, runs of spaces collapsed; the result matches
    /// `[a-z0-9][a-z0-9 _-]{0,31}`, or is the reserved `@profile` when [reserved] allows it.
    public static func normalizeTag(_ s: String, reserved: Bool = false) throws -> String {
        guard len(s) <= 4 * maxTagLength else { throw CryptoError.format("tag") }
        var out = ""
        var space = false
        var trimmed = Substring(s)
        while trimmed.first == " " { trimmed.removeFirst() }
        while trimmed.last == " " { trimmed.removeLast() }
        for c in trimmed.unicodeScalars {
            if c == " " {
                if !space { out.unicodeScalars.append(c) }
                space = true
                continue
            }
            space = false
            out.unicodeScalars.append(("A"..."Z").contains(c) ? Unicode.Scalar(c.value + 32)! : c)
        }
        if out == profileTag {
            guard reserved else { throw CryptoError.format("tag") }
            return out
        }
        let b = Array(out.utf8)
        guard (1...maxTagLength).contains(b.count), isLower(b[0]) || isDigit(b[0]),
              b.allSatisfy({ isLower($0) || isDigit($0) || " _-".utf8.contains($0) }) else { throw CryptoError.format("tag") }
        return out
    }

    /// Normalises a tag list: at most 16, sorted, without duplicates.
    public static func normalizeTags(_ tags: [String], reserved: Bool = false) throws -> [String] {
        guard tags.count <= maxTags else { throw CryptoError.format("tags") }
        return Array(Set(try tags.map { try normalizeTag($0, reserved: reserved) })).sorted(by: utf8Less)
    }

    /// Byte order of the UTF-8 encodings, as Go and Kotlin sort the tags (Kotlin's by UTF-16 units, which agree for the
    /// ASCII a tag is made of).
    public static func utf8Less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
}
