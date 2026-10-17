import Foundation

/// Canonical base64 (VAULT-MESSAGING §5.3): standard base64 with padding for JSON members, unpadded base64url
/// (RFC 4648 §5) for QR codes and links. Decoding rejects CR, LF and every non-canonical encoding (missing or extra
/// padding, non-zero trailing bits), like the Go reference's strictjson. Mirrors vettid-android `Base64s`.
public enum Base64s {
    public static func encodeStd(_ b: [UInt8]) -> String { Data(b).base64EncodedString() }

    public static func encodeRawUrl(_ b: [UInt8]) -> String {
        var s = encodeStd(b)
        while s.hasSuffix("=") { s.removeLast() }
        return String(s.map { $0 == "+" ? "-" : $0 == "/" ? "_" : $0 })
    }

    /// Decodes canonical standard base64; [n] >= 0 requires that length.
    public static func decodeStd(_ s: String, _ n: Int = -1) throws -> [UInt8] {
        guard !s.utf8.contains(where: { $0 == 0x0D || $0 == 0x0A }),
              s.utf8.allSatisfy(isStdChar),
              let data = Data(base64Encoded: s)
        else { throw CryptoError.format("base64") }
        return try checked(Array(data), n, canonical: encodeStd(Array(data)) == s)
    }

    /// Decodes canonical unpadded base64url; [n] >= 0 requires that length.
    public static func decodeRawUrl(_ s: String, _ n: Int = -1) throws -> [UInt8] {
        guard s.utf8.allSatisfy(isUrlChar) else { throw CryptoError.format("base64") }
        var std = String(s.map { $0 == "-" ? "+" : $0 == "_" ? "/" : $0 })
        while std.utf8.count % 4 != 0 { std.append("=") }
        guard let data = Data(base64Encoded: std) else { throw CryptoError.format("base64") }
        return try checked(Array(data), n, canonical: encodeRawUrl(Array(data)) == s)
    }

    private static func checked(_ b: [UInt8], _ n: Int, canonical: Bool) throws -> [UInt8] {
        if n >= 0, b.count != n { throw CryptoError.format("base64 length") }
        guard canonical else { throw CryptoError.format("base64 not canonical") }
        return b
    }

    private static func isStdChar(_ c: UInt8) -> Bool {
        isAlnum(c) || c == 0x2B || c == 0x2F || c == 0x3D // + / =
    }

    private static func isUrlChar(_ c: UInt8) -> Bool {
        isAlnum(c) || c == 0x2D || c == 0x5F // - _
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
    }
}
