import CryptoKit
import Foundation

/// Byte helpers used across the protocol code. Every comparison of a tag, key, hash commitment or kid goes through
/// ``constantTimeEquals(_:_:)`` (VAULT-MESSAGING §13.6); every buffer that held a secret is cleared with ``wipe(_:)``
/// when the code that owns it is done with it. Mirrors vettid-android `Bytes`.
public enum Bytes {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Compares two byte strings in time that depends only on their lengths. Different lengths are unequal.
    public static func constantTimeEquals(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a, let b, a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Overwrites [b] with zeros. Swift may have copied a secret elsewhere (copy-on-write, library internals), so this
    /// is best-effort hygiene that shortens the life of the copies this code controls, as in the Go reference.
    public static func wipe(_ b: inout [UInt8]) {
        for i in b.indices { b[i] = 0 }
    }

    /// Concatenates byte arrays.
    public static func concat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    /// Lowercase hex.
    public static func hex(_ b: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(b.count * 2)
        for x in b {
            out.append(hexDigits[Int(x >> 4)])
            out.append(hexDigits[Int(x & 0x0F)])
        }
        return String(out.map { Character(Unicode.Scalar($0)) }) // ASCII digits
    }

    /// Parses lowercase hex strictly (even length, `[0-9a-f]` only).
    public static func unhex(_ s: String) throws -> [UInt8] {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { throw CryptoError.format("hex") }
        var out = [UInt8](repeating: 0, count: chars.count / 2)
        for i in out.indices {
            guard let hi = nibble(chars[2 * i]), let lo = nibble(chars[2 * i + 1]) else { throw CryptoError.format("hex") }
            out[i] = hi << 4 | lo
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }

    /// Reports whether [s] is exactly [n] lowercase hex characters.
    public static func isLowerHex(_ s: String, _ n: Int) -> Bool {
        s.utf8.count == n && s.utf8.allSatisfy { nibble($0) != nil }
    }

    /// SHA-256 of the concatenation of [parts].
    public static func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Array(h.finalize())
    }

    /// SHA-256(label || parts...): the labelled hash of VAULT-MESSAGING §4.
    public static func labeledHash(_ label: String, _ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        h.update(data: Array(label.utf8))
        for p in parts { h.update(data: p) }
        return Array(h.finalize())
    }

    /// Big-endian encoding of [v] in [n] bytes.
    public static func uintBE(_ v: UInt64, _ n: Int) -> [UInt8] {
        (0..<n).map { i in UInt8(truncatingIfNeeded: v >> (8 * UInt64(n - 1 - i))) }
    }

    /// Reads a big-endian unsigned integer of up to 8 bytes.
    public static func readUintBE(_ b: [UInt8], _ off: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n { v = v << 8 | UInt64(b[off + i]) }
        return v
    }
}
