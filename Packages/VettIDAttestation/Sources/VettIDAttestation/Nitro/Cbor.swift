import Foundation

/// The subset of CBOR (RFC 8949) that COSE_Sign1 attestation documents use, as vettid-vault `internal/cbor` and
/// vettid-android `CborValue`: unsigned and negative integers, byte and text strings (definite length), arrays and
/// maps (definite or indefinite length, as the NSM emits), tags, booleans and null. Floats, undefined, other simple
/// values and indefinite strings are refused, as are duplicate map keys, nesting deeper than ``maxDepth`` and trailing
/// data.
public indirect enum CborValue: Equatable, Sendable {
    case uint(UInt64)
    /// A negative integer: the value is -1 - arg.
    case nint(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CborValue])
    case map([CborPair])
    case tag(UInt64, CborValue)
    case bool(Bool)
    case null

    public static let maxDepth = 16

    public static func decode(_ b: [UInt8]) throws -> CborValue {
        var d = CborDecoder(b: b)
        let v = try d.item(depth: 0)
        guard d.off == b.count else { throw AttestationError.format("cbor trailing data") }
        return v
    }

    /// Decodes exactly one item from the start of [b] and returns it with the number of bytes it takes, for formats
    /// that concatenate CBOR items with other data (App Attest authenticator data: the COSE key, then the extensions
    /// map). The item is decoded under the same rules as ``decode(_:)``; only the trailing-data check is left to the
    /// caller. As vettid-vault `cbor.DecodePrefix`. Empty input is truncated.
    public static func decodePrefix(_ b: [UInt8]) throws -> (value: CborValue, length: Int) {
        var d = CborDecoder(b: b)
        let v = try d.item(depth: 0)
        return (v, d.off)
    }

    /// Removes tag [tag] if present.
    public func untag(_ tag: UInt64) -> CborValue {
        if case .tag(let t, let item) = self, t == tag { return item }
        return self
    }

    /// The entries of a map, or nil.
    public var entries: [CborPair]? {
        if case .map(let e) = self { return e }
        return nil
    }

    /// The value of text key [key] in a map, or nil.
    public func lookup(_ key: String) -> CborValue? { entries?.first { $0.key == .text(key) }?.value }

    /// The value of integer key [key] in a map, or nil.
    public func lookup(int key: Int64) -> CborValue? {
        let k: CborValue = key >= 0 ? .uint(UInt64(key)) : .nint(UInt64(-1 - key))
        return entries?.first { $0.key == k }?.value
    }

    public func bytes(at key: String) throws -> [UInt8] {
        guard case .bytes(let b)? = lookup(key) else { throw AttestationError.format("cbor \(key)") }
        return b
    }

    public func text(at key: String) throws -> String {
        guard case .text(let s)? = lookup(key) else { throw AttestationError.format("cbor \(key)") }
        return s
    }

    public func uint(at key: String) throws -> UInt64 {
        guard case .uint(let v)? = lookup(key) else { throw AttestationError.format("cbor \(key)") }
        return v
    }
}

/// One map entry.
public struct CborPair: Equatable, Sendable {
    public let key: CborValue
    public let value: CborValue
}

private struct CborDecoder {
    let b: [UInt8]
    var off = 0

    private func fail(_ what: String) -> AttestationError { .format("cbor \(what)") }

    private struct Head {
        let major: UInt8
        let arg: UInt64
        let indefinite: Bool
    }

    private mutating func head() throws -> Head {
        guard off < b.count else { throw fail("truncated") }
        let ib = b[off]
        off += 1
        let major = ib >> 5
        let ai = ib & 0x1F
        switch ai {
        case ..<24:
            return Head(major: major, arg: UInt64(ai), indefinite: false)
        case 31 where major == 4 || major == 5:
            return Head(major: major, arg: 0, indefinite: true)
        case 24...27:
            let n = 1 << Int(ai - 24)
            guard b.count - off >= n else { throw fail("truncated") }
            var v: UInt64 = 0
            for _ in 0..<n {
                v = v << 8 | UInt64(b[off])
                off += 1
            }
            // Lengths and integers above 2^63 - 1 are not used by attestation documents.
            guard v <= UInt64(Int64.max) else { throw fail("integer too large") }
            return Head(major: major, arg: v, indefinite: false)
        default:
            throw fail("unsupported item") // reserved 28–30, indefinite strings, a stray break
        }
    }

    private mutating func atBreak() throws -> Bool {
        guard off < b.count else { throw fail("truncated") }
        if b[off] == 0xFF {
            off += 1
            return true
        }
        return false
    }

    mutating func item(depth: Int) throws -> CborValue {
        guard depth <= CborValue.maxDepth else { throw fail("nesting too deep") }
        let start = off
        let h = try head()
        if h.indefinite { return try indefinite(h, depth: depth) }
        switch h.major {
        case 0: return .uint(h.arg)
        case 1: return .nint(h.arg)
        case 2, 3: return try string(h)
        case 4, 5: return try container(h, depth: depth)
        case 6: return .tag(h.arg, try item(depth: depth + 1))
        default: return try simple(h, start: start)
        }
    }

    private mutating func indefinite(_ h: Head, depth: Int) throws -> CborValue {
        if h.major == 4 {
            var items: [CborValue] = []
            while !(try atBreak()) { items.append(try item(depth: depth + 1)) }
            return .array(items)
        }
        var entries: [CborPair] = []
        while !(try atBreak()) { entries.append(try pair(depth: depth, seen: entries)) }
        return .map(entries)
    }

    private mutating func string(_ h: Head) throws -> CborValue {
        guard h.arg <= UInt64(b.count - off) else { throw fail("truncated") }
        let s = Array(b[off..<(off + Int(h.arg))])
        off += Int(h.arg)
        if h.major == 2 { return .bytes(s) }
        guard let text = String(bytes: s, encoding: .utf8), Array(text.utf8) == s else { throw fail("invalid UTF-8") }
        return .text(text)
    }

    private mutating func container(_ h: Head, depth: Int) throws -> CborValue {
        if h.major == 4 {
            guard h.arg <= UInt64(b.count - off) else { throw fail("truncated") }
            var items: [CborValue] = []
            for _ in 0..<h.arg { items.append(try item(depth: depth + 1)) }
            return .array(items)
        }
        guard h.arg <= UInt64((b.count - off) / 2) else { throw fail("truncated") }
        var entries: [CborPair] = []
        for _ in 0..<h.arg { entries.append(try pair(depth: depth, seen: entries)) }
        return .map(entries)
    }

    private func simple(_ h: Head, start: Int) throws -> CborValue {
        guard (20...22).contains(h.arg) else { throw fail("unsupported simple value") } // undefined, floats, others
        guard off - start == 1 else { throw fail("non-minimal simple value") }
        return h.arg == 22 ? .null : .bool(h.arg == 21)
    }

    private mutating func pair(depth: Int, seen: [CborPair]) throws -> CborPair {
        let k = try item(depth: depth + 1)
        switch k {
        case .uint, .nint, .text, .bytes: break
        default: throw fail("map key type")
        }
        guard !seen.contains(where: { $0.key == k }) else { throw fail("duplicate map key") }
        return CborPair(key: k, value: try item(depth: depth + 1))
    }
}

/// A minimal definite-length CBOR encoder (the COSE Sig_structure, test documents).
public final class CborEncoder {
    private var out: [UInt8] = []

    public init() {}

    private func head(_ major: UInt8, _ arg: UInt64) {
        let m = major << 5
        switch arg {
        case ..<24: out.append(m | UInt8(arg))
        case ...0xFF: out += [m | 24, UInt8(arg)]
        case ...0xFFFF: out += [m | 25] + (0..<2).reversed().map { UInt8(truncatingIfNeeded: arg >> (8 * $0)) }
        case ...0xFFFF_FFFF: out += [m | 26] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: arg >> (8 * $0)) }
        default: out += [m | 27] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: arg >> (8 * $0)) }
        }
    }

    @discardableResult public func uint(_ v: UInt64) -> CborEncoder {
        head(0, v)
        return self
    }

    @discardableResult public func int(_ v: Int64) -> CborEncoder {
        if v >= 0 { head(0, UInt64(v)) } else { head(1, UInt64(-1 - v)) }
        return self
    }

    @discardableResult public func bytes(_ v: [UInt8]) -> CborEncoder {
        head(2, UInt64(v.count))
        out += v
        return self
    }

    @discardableResult public func text(_ v: String) -> CborEncoder {
        head(3, UInt64(v.utf8.count))
        out += Array(v.utf8)
        return self
    }

    @discardableResult public func array(_ n: Int) -> CborEncoder {
        head(4, UInt64(n))
        return self
    }

    @discardableResult public func map(_ n: Int) -> CborEncoder {
        head(5, UInt64(n))
        return self
    }

    @discardableResult public func tag(_ t: UInt64) -> CborEncoder {
        head(6, t)
        return self
    }

    @discardableResult public func null() -> CborEncoder {
        out.append(0xF6)
        return self
    }

    @discardableResult public func raw(_ b: [UInt8]) -> CborEncoder {
        out += b
        return self
    }

    public func encoded() -> [UInt8] { out }
}
