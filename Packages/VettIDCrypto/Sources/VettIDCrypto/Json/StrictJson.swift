import Foundation

// The parser decodes slices of a document already validated as UTF-8 (`parseObject`) and strings built from valid
// scalars, so `String(decoding:)` cannot lose anything here.
// swiftlint:disable optional_data_string_conversion

/// Strict JSON for the vault messaging wire format (VAULT-MESSAGING §5.3), the twin of the Go reference's
/// `internal/strictjson` and of vettid-android `StrictJson`:
///
/// - valid UTF-8, exactly one top-level object, nothing after it but white space;
/// - no duplicate member names at any depth (names are case-sensitive and compared as their UTF-8 bytes, not by
///   Unicode equivalence, as Go and Kotlin compare them);
/// - nesting at most ``maxDepth``;
/// - integers as plain JSON integers (no sign, fraction, exponent or leading zero) no larger than 2^53 − 1.
///
/// Errors never echo input bytes.
public enum StrictJson {
    public static let maxDepth = 32
    public static let maxSafeInteger: UInt64 = (1 << 53) - 1

    /// Parses [b] as exactly one JSON object, nested at most [maxDepth] deep (an object with no container inside is depth
    /// 1): for a value that is copied into a larger document, whose own nesting limit is for the whole (a value at level
    /// L of a document limited to ``maxDepth`` has `maxDepth - L + 1` left).
    public static func parseObject(_ b: [UInt8], maxDepth: Int = StrictJson.maxDepth) throws -> JsonObject {
        guard String(bytes: b, encoding: .utf8) != nil else { throw CryptoError.format("json: invalid UTF-8") }
        var parser = JsonParser(b, maxDepth: maxDepth)
        guard case .object(let o) = try parser.parseDocument() else { throw CryptoError.format("json: not an object") }
        return o
    }

    /// Parses [s] as exactly one JSON object.
    public static func parseObject(_ s: String) throws -> JsonObject { try parseObject(Array(s.utf8)) }

    /// Validates [raw] as a strict JSON object and returns its compact form (white space outside strings removed,
    /// everything else byte for byte), as Go's json.Compact does.
    public static func compactObject(_ raw: [UInt8], maxDepth: Int = StrictJson.maxDepth) throws -> [UInt8] {
        _ = try parseObject(raw, maxDepth: maxDepth)
        return compact(raw)
    }

    /// Removes insignificant white space from already-validated JSON.
    public static func compact(_ raw: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(raw.count)
        var inString = false
        var escaped = false
        for c in raw {
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == 0x5C {
                    escaped = true
                } else if c == 0x22 {
                    inString = false
                }
                continue
            }
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D: break
            case 0x22:
                inString = true
                out.append(c)
            default: out.append(c)
            }
        }
        return out
    }

    /// Parses the text of a plain JSON integer in [min, max] (≤ 2^53 − 1).
    static func parseUint(_ text: String, min: UInt64, max: UInt64) throws -> UInt64 {
        let digits = Array(text.utf8)
        guard !digits.isEmpty, digits.count <= 16, digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
            throw CryptoError.format("json: integer")
        }
        if digits.count > 1, digits[0] == 0x30 { throw CryptoError.format("json: integer") }
        guard let v = UInt64(text), v >= min, v <= max, v <= maxSafeInteger else {
            throw CryptoError.format("json: integer out of range")
        }
        return v
    }
}

/// A parsed JSON value; each carries its exact source text (`raw`).
public enum JsonValue: Sendable {
    case string(raw: String, value: String)
    case number(raw: String)
    case bool(raw: String, value: Bool)
    case null(raw: String)
    case array(raw: String, items: [JsonValue])
    case object(JsonObject)

    /// The exact source text of this value.
    public var raw: String {
        switch self {
        case .string(let raw, _), .number(let raw), .bool(let raw, _), .null(let raw), .array(let raw, _): raw
        case .object(let o): o.raw
        }
    }

    /// The exact source bytes of this value (UTF-8).
    public var rawBytes: [UInt8] { Array(raw.utf8) }

    /// Reads an array element as a string.
    public func asString() throws -> String {
        guard case .string(_, let v) = self else { throw CryptoError.format("json: not a string") }
        return v
    }

    /// Reads an array element as an object.
    public func asObject() throws -> JsonObject {
        guard case .object(let o) = self else { throw CryptoError.format("json: not an object") }
        return o
    }

    /// Reads an array element as an integer in [min, max].
    public func asUint(min: UInt64, max: UInt64) throws -> UInt64 {
        guard case .number(let raw) = self else { throw CryptoError.format("json: not an integer") }
        return try StrictJson.parseUint(raw, min: min, max: max)
    }
}

/// A parsed object with typed, strict accessors. Unknown members are ignored by callers (§5.3); known members must
/// have exactly the specified type. Member names are matched by their UTF-8 bytes.
public struct JsonObject: Sendable {
    public let raw: String
    /// The members in source order.
    public let members: [(name: String, value: JsonValue)]

    init(raw: String, members: [(name: String, value: JsonValue)]) {
        self.raw = raw
        self.members = members
    }

    public func has(_ name: String) -> Bool { self[name] != nil }

    public subscript(_ name: String) -> JsonValue? {
        let key = Array(name.utf8)
        return members.first { Array($0.name.utf8) == key }?.value
    }

    private func require(_ name: String) throws -> JsonValue {
        guard let v = self[name] else { throw CryptoError.format("json: missing \(name)") }
        return v
    }

    public func string(_ name: String) throws -> String {
        guard case .string(_, let v) = try require(name) else { throw CryptoError.format("json: \(name) is not a string") }
        return v
    }

    /// An optional string; nil when absent.
    public func optString(_ name: String) throws -> String? { has(name) ? try string(name) : nil }

    public func uint(_ name: String, min: UInt64, max: UInt64) throws -> UInt64 {
        guard case .number(let raw) = try require(name) else { throw CryptoError.format("json: \(name) is not an integer") }
        return try StrictJson.parseUint(raw, min: min, max: max)
    }

    public func optUint(_ name: String, min: UInt64, max: UInt64) throws -> UInt64? {
        has(name) ? try uint(name, min: min, max: max) : nil
    }

    public func bool(_ name: String) throws -> Bool {
        guard case .bool(_, let v) = try require(name) else { throw CryptoError.format("json: \(name) is not a boolean") }
        return v
    }

    public func obj(_ name: String) throws -> JsonObject {
        guard case .object(let o) = try require(name) else { throw CryptoError.format("json: \(name) is not an object") }
        return o
    }

    public func optObj(_ name: String) throws -> JsonObject? { has(name) ? try obj(name) : nil }

    public func array(_ name: String) throws -> [JsonValue] {
        guard case .array(_, let items) = try require(name) else { throw CryptoError.format("json: \(name) is not an array") }
        return items
    }

    public func optArray(_ name: String) throws -> [JsonValue]? { has(name) ? try array(name) : nil }

    /// A required member holding canonical standard base64 of [n] bytes (n < 0: any).
    public func base64(_ name: String, _ n: Int = -1) throws -> [UInt8] { try Base64s.decodeStd(string(name), n) }
}

/// The parser, over the UTF-8 bytes of a validated document.
private struct JsonParser {
    private let s: [UInt8]
    private var i = 0
    private let maxDepth: Int

    init(_ bytes: [UInt8], maxDepth: Int = StrictJson.maxDepth) {
        s = bytes
        self.maxDepth = maxDepth
    }

    mutating func parseDocument() throws -> JsonValue {
        ws()
        guard i < s.count, s[i] == UInt8(ascii: "{") else { throw CryptoError.format("json: not an object") }
        let v = try value(0)
        ws()
        guard i == s.count else { throw CryptoError.format("json: trailing data") }
        return v
    }

    private func fail() -> CryptoError { CryptoError.format("json: syntax") }

    private func text(_ from: Int) -> String { String(decoding: s[from..<i], as: UTF8.self) }

    private mutating func ws() {
        while i < s.count, s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D { i += 1 }
    }

    private mutating func value(_ depth: Int) throws -> JsonValue {
        guard i < s.count else { throw fail() }
        switch s[i] {
        case UInt8(ascii: "{"): return .object(try obj(depth + 1))
        case UInt8(ascii: "["): return try arr(depth + 1)
        case UInt8(ascii: "\""):
            let start = i
            let v = try str()
            return .string(raw: text(start), value: String(decoding: v, as: UTF8.self))
        case UInt8(ascii: "t"): return try literal("true") { .bool(raw: $0, value: true) }
        case UInt8(ascii: "f"): return try literal("false") { .bool(raw: $0, value: false) }
        case UInt8(ascii: "n"): return try literal("null") { .null(raw: $0) }
        default: return try num()
        }
    }

    private mutating func literal(_ word: String, _ make: (String) -> JsonValue) throws -> JsonValue {
        let w = Array(word.utf8)
        guard i + w.count <= s.count, Array(s[i..<i + w.count]) == w else { throw fail() }
        i += w.count
        return make(word)
    }

    private mutating func obj(_ depth: Int) throws -> JsonObject {
        guard depth <= maxDepth else { throw CryptoError.format("json: nesting too deep") }
        let start = i
        i += 1 // {
        var members: [(name: String, value: JsonValue)] = []
        var names = Set<[UInt8]>()
        ws()
        if i < s.count, s[i] == UInt8(ascii: "}") {
            i += 1
            return JsonObject(raw: text(start), members: members)
        }
        while true {
            ws()
            guard i < s.count, s[i] == UInt8(ascii: "\"") else { throw fail() }
            let name = try str()
            guard names.insert(name).inserted else { throw CryptoError.format("json: duplicate member name") }
            ws()
            guard i < s.count, s[i] == UInt8(ascii: ":") else { throw fail() }
            i += 1
            ws()
            members.append((String(decoding: name, as: UTF8.self), try value(depth)))
            ws()
            guard i < s.count else { throw fail() }
            switch s[i] {
            case UInt8(ascii: ","): i += 1
            case UInt8(ascii: "}"):
                i += 1
                return JsonObject(raw: text(start), members: members)
            default: throw fail()
            }
        }
    }

    private mutating func arr(_ depth: Int) throws -> JsonValue {
        guard depth <= maxDepth else { throw CryptoError.format("json: nesting too deep") }
        let start = i
        i += 1 // [
        var items: [JsonValue] = []
        ws()
        if i < s.count, s[i] == UInt8(ascii: "]") {
            i += 1
            return .array(raw: text(start), items: items)
        }
        while true {
            ws()
            items.append(try value(depth))
            ws()
            guard i < s.count else { throw fail() }
            switch s[i] {
            case UInt8(ascii: ","): i += 1
            case UInt8(ascii: "]"):
                i += 1
                return .array(raw: text(start), items: items)
            default: throw fail()
            }
        }
    }

    /// A string's decoded UTF-8 bytes. One case per escape, as the grammar has them.
    private mutating func str() throws -> [UInt8] { // swiftlint:disable:this cyclomatic_complexity
        i += 1 // opening quote
        var out = [UInt8]()
        while true {
            guard i < s.count else { throw fail() }
            let c = s[i]
            i += 1
            switch c {
            case UInt8(ascii: "\""): return out
            case ..<0x20: throw fail() // raw control characters are not allowed
            case UInt8(ascii: "\\"):
                guard i < s.count else { throw fail() }
                let e = s[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"): out.append(contentsOf: Array(String(try unicodeEscape()).utf8))
                default: throw fail()
                }
            default: out.append(c)
            }
        }
    }

    /// \uXXXX, combining surrogate pairs; a lone surrogate decodes to U+FFFD, as Go's encoding/json does.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        let hi = try hex4()
        if (0xD800...0xDBFF).contains(hi), i + 1 < s.count, s[i] == UInt8(ascii: "\\"), s[i + 1] == UInt8(ascii: "u") {
            let save = i
            i += 2
            let lo = try hex4()
            if (0xDC00...0xDFFF).contains(lo), let scalar = Unicode.Scalar(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)) {
                return scalar
            }
            i = save
        }
        return Unicode.Scalar(hi) ?? "\u{FFFD}"
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= s.count else { throw fail() }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = s[i]
            i += 1
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw fail()
            }
            v = v << 4 | d
        }
        return v
    }

    /// The JSON number grammar: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    private mutating func num() throws -> JsonValue {
        let start = i
        if i < s.count, s[i] == UInt8(ascii: "-") { i += 1 }
        guard i < s.count else { throw fail() }
        if s[i] == UInt8(ascii: "0") {
            i += 1
        } else if (0x31...0x39).contains(s[i]) {
            while i < s.count, (0x30...0x39).contains(s[i]) { i += 1 }
        } else {
            throw fail()
        }
        if i < s.count, s[i] == UInt8(ascii: ".") {
            i += 1
            try digits()
        }
        if i < s.count, s[i] == UInt8(ascii: "e") || s[i] == UInt8(ascii: "E") {
            i += 1
            if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") { i += 1 }
            try digits()
        }
        return .number(raw: text(start))
    }

    private mutating func digits() throws {
        let start = i
        while i < s.count, (0x30...0x39).contains(s[i]) { i += 1 }
        guard i > start else { throw fail() }
    }
}

/// Writes a compact JSON object with members in call order. Strings are encoded exactly as the Go reference encodes
/// them (encoding/json without HTML escaping), so both implementations produce the same bytes for the same message:
/// that is what the §16 vectors pin. Mirrors vettid-android `JsonBuilder`.
public final class JsonBuilder {
    private var out = "{"
    private var first = true

    public init() {}

    private func name(_ n: String) {
        if !first { out.append(",") }
        first = false
        Self.appendString(&out, n)
        out.append(":")
    }

    @discardableResult
    public func string(_ n: String, _ v: String) -> JsonBuilder {
        name(n)
        Self.appendString(&out, v)
        return self
    }

    @discardableResult
    public func uint(_ n: String, _ v: UInt64) -> JsonBuilder {
        name(n)
        out.append(String(v))
        return self
    }

    @discardableResult
    public func bool(_ n: String, _ v: Bool) -> JsonBuilder {
        name(n)
        out.append(v ? "true" : "false")
        return self
    }

    @discardableResult
    public func base64(_ n: String, _ v: [UInt8]) -> JsonBuilder { string(n, Base64s.encodeStd(v)) }

    /// Adds a member whose value is already-encoded JSON (the caller vouches for it).
    @discardableResult
    public func raw(_ n: String, _ v: String) -> JsonBuilder {
        name(n)
        out.append(v)
        return self
    }

    @discardableResult
    public func raw(_ n: String, _ v: [UInt8]) -> JsonBuilder { raw(n, String(decoding: v, as: UTF8.self)) }

    /// Closes the object.
    public func build() -> String { out + "}" }

    public func bytes() -> [UInt8] { Array(build().utf8) }

    /// Encodes [s] as a JSON string, Go-compatible.
    public static func quote(_ s: String) -> String {
        var out = ""
        appendString(&out, s)
        return out
    }

    /// A JSON array of already-encoded elements.
    public static func array(_ elements: [String]) -> String { "[" + elements.joined(separator: ",") + "]" }

    private static let hexDigits = Array("0123456789abcdef")

    /// One case per escape, as Go's encoder has them.
    static func appendString(_ out: inout String, _ s: String) { // swiftlint:disable:this cyclomatic_complexity
        out.append("\"")
        for c in s.unicodeScalars {
            switch c {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\u{2028}": out.append("\\u2028")
            case "\u{2029}": out.append("\\u2029")
            default:
                if c.value < 0x20 {
                    out.append("\\u00")
                    out.append(hexDigits[Int(c.value >> 4)])
                    out.append(hexDigits[Int(c.value & 0xF)])
                } else {
                    out.unicodeScalars.append(c)
                }
            }
            // Swift strings hold only valid scalars, so the lone surrogates Go and Kotlin turn into U+FFFD cannot occur.
        }
        out.append("\"")
    }
}
// swiftlint:enable optional_data_string_conversion
