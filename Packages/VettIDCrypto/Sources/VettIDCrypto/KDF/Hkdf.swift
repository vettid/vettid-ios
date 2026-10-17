import CryptoKit

/// HKDF-SHA-256 (RFC 5869), extract-then-expand, as used throughout VAULT-MESSAGING §4. Mirrors vettid-android `Hkdf`.
public enum Hkdf {
    private static let hashLen = 32
    private static let maxLen = 255 * hashLen

    private static func mac(_ key: [UInt8], _ parts: [UInt8]...) -> [UInt8] {
        // HMAC keys may be empty (RFC 5869: the default salt is HashLen zeros).
        var h = HMAC<SHA256>(key: SymmetricKey(data: key.isEmpty ? [UInt8](repeating: 0, count: hashLen) : key))
        for p in parts { h.update(data: p) }
        return Array(h.finalize())
    }

    /// HKDF-Extract(salt, ikm). An empty salt means HashLen zeros.
    public static func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] { mac(salt, ikm) }

    /// HKDF-Expand(prk, info, length).
    public static func expand(prk: [UInt8], info: [UInt8], length: Int) throws -> [UInt8] {
        guard (0...maxLen).contains(length) else { throw CryptoError.key("hkdf length") }
        var out = [UInt8]()
        out.reserveCapacity(length)
        var t = [UInt8]()
        var counter: UInt8 = 1
        while out.count < length {
            let next = mac(prk, t, info, [counter])
            Bytes.wipe(&t)
            t = next
            out.append(contentsOf: t.prefix(length - out.count))
            counter &+= 1
        }
        Bytes.wipe(&t)
        return out
    }

    /// HKDF-SHA-256(ikm, salt, info, L): extract then expand.
    public static func derive(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) throws -> [UInt8] {
        var prk = extract(salt: salt, ikm: ikm)
        defer { Bytes.wipe(&prk) }
        return try expand(prk: prk, info: info, length: length)
    }
}

/// HMAC-SHA-256 of the concatenation of [parts] under [key].
public func hmacSHA256(key: [UInt8], _ parts: [UInt8]...) -> [UInt8] {
    var h = HMAC<SHA256>(key: SymmetricKey(data: key))
    for p in parts { h.update(data: p) }
    return Array(h.finalize())
}
