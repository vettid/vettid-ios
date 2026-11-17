import Foundation

/// The JSON Canonicalization Scheme (RFC 8785) for the documents VettID signs or hashes (VAULT-MESSAGING §10.4
/// "Approval documents", BALLOT-PROTOCOL §2), the twin of vettid-vault `vms/jcs`. Those documents hold only objects,
/// arrays, strings, integers, booleans and null, so RFC 8785's number rule reduces to plain integers within 2^53 − 1:
/// a value parsed by ``StrictJson`` is written back with its keys sorted by UTF-16 code units, no white space, its
/// strings escaped as ECMAScript's `JSON.stringify` escapes them, and its integers in decimal.
public enum Jcs {
    /// [value] in its canonical form; throws for a number that is not a plain integer within 2^53 − 1 (a document's
    /// caller checks its own rules first; this one is the format's).
    public static func canonical(_ value: JsonValue) throws -> [UInt8] {
        var out: [UInt8] = []
        try append(value, to: &out)
        return out
    }

    private static func append(_ value: JsonValue, to out: inout [UInt8]) throws {
        switch value {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(_, let v): out.append(contentsOf: Array((v ? "true" : "false").utf8))
        case .number(let raw):
            guard isInteger(raw) else { throw CryptoError.format("jcs: not an integer") }
            out.append(contentsOf: Array(raw.utf8))
        case .string(_, let v): appendString(v, to: &out)
        case .array(_, let items):
            out.append(UInt8(ascii: "["))
            for (i, e) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                try append(e, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o): try appendObject(o, to: &out)
        }
    }

    /// RFC 8785 §3.2.3: the members sorted by their names' UTF-16 code units.
    private static func appendObject(_ o: JsonObject, to out: inout [UInt8]) throws {
        let members = o.members.sorted { lessUTF16($0.name, $1.name) }
        out.append(UInt8(ascii: "{"))
        for (i, m) in members.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            appendString(m.name, to: &out)
            out.append(UInt8(ascii: ":"))
            try append(m.value, to: &out)
        }
        out.append(UInt8(ascii: "}"))
    }

    /// A plain JSON integer: digits only, no leading zero, at most 2^53 − 1.
    public static func isInteger(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (0x30...0x39).contains($0) }), raw == "0" || !raw.hasPrefix("0"),
              let n = UInt64(raw)
        else { return false }
        return n <= StrictJson.maxSafeInteger
    }

    static func lessUTF16(_ a: String, _ b: String) -> Bool {
        let ua = Array(a.utf16), ub = Array(b.utf16)
        for (x, y) in zip(ua, ub) where x != y { return x < y }
        return ua.count < ub.count
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// RFC 8785 §3.2.2.2: the two-character escapes, `\u00xx` (lower-case hex) for the other control characters, and
    /// every other character as itself.
    private static func appendString(_ s: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: Array("\\\"".utf8))
            case "\\": out.append(contentsOf: Array("\\\\".utf8))
            case "\u{08}": out.append(contentsOf: Array("\\b".utf8))
            case "\u{0C}": out.append(contentsOf: Array("\\f".utf8))
            case "\n": out.append(contentsOf: Array("\\n".utf8))
            case "\r": out.append(contentsOf: Array("\\r".utf8))
            case "\t": out.append(contentsOf: Array("\\t".utf8))
            default:
                if scalar.value < 0x20 {
                    out.append(contentsOf: Array("\\u00".utf8))
                    out.append(hexDigits[Int(scalar.value >> 4)])
                    out.append(hexDigits[Int(scalar.value & 15)])
                } else {
                    out.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
