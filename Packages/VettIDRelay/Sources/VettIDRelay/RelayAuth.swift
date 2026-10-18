import Foundation
import VettIDCrypto

/// The client side of the relay's authentication (RELAY-PROTOCOL §3.2, §4.1), as vettid-relay's `relayauth`: mailbox
/// ids, canonical request digests and the three signed-request headers. Everything signed and sent is ASCII whatever
/// the phone's language and region. Mirrors vettid-android `RelayAuth`.
public enum RelayAuth {
    public static let headerKey = "X-VettID-Key"
    public static let headerTimestamp = "X-VettID-Timestamp"
    public static let headerSig = "X-VettID-Sig"

    /// hex(SHA-256("")): the body hash of bodiless requests.
    public static let emptyBodyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static let keyBase64Length = 44

    /// lowercase(base32(SHA-256(pub))) without padding, first 26 characters (§3.2).
    public static func mailboxID(_ pub: [UInt8]) -> String { Mailbox.id(pub) }

    /// Whether [s] has the shape of a mailbox id.
    public static func isValidMailboxID(_ s: String) -> Bool {
        s.utf8.count == Mailbox.length && s.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x32...0x37).contains($0) }
    }

    /// Canonical (standard, padded) base64 of a public key: a token's `sub`, the `X-VettID-Key` header.
    public static func encodeKey(_ pub: [UInt8]) -> String { Base64s.encodeStd(pub) }

    /// Strictly decodes a base64 Ed25519 public key, or nil.
    public static func decodeKey(_ s: String) -> [UInt8]? {
        guard s.utf8.count == keyBase64Length else { return nil }
        return try? Base64s.decodeStd(s, Suite.ed25519PublicSize)
    }

    /// SHA-256 over the exact body bytes (empty for bodiless requests).
    public static func bodyHash(_ body: [UInt8]?) -> [UInt8] { Bytes.sha256(body ?? []) }

    /// METHOD "\n" PATH "\n" timestamp "\n" lowercase-hex(SHA-256(body)).
    public static func canonical(method: String, path: String, timestamp: String, bodyHash: [UInt8]) -> [UInt8] {
        Array((upperASCII(method) + "\n" + path + "\n" + timestamp + "\n" + Bytes.hex(bodyHash)).utf8)
    }

    /// SHA-256(canonical): what is Ed25519-signed.
    public static func digest(method: String, path: String, timestamp: String, bodyHash: [UInt8]) -> [UInt8] {
        Bytes.sha256(canonical(method: method, path: path, timestamp: timestamp, bodyHash: bodyHash))
    }

    /// Ed25519(key, digest). Deterministic.
    public static func signRequest(
        _ key: Ed25519PrivateKey, method: String, path: String, timestamp: String, bodyHash: [UInt8]
    ) throws -> [UInt8] {
        try key.signRaw(digest(method: method, path: path, timestamp: timestamp, bodyHash: bodyHash))
    }

    /// RFC 3339 UTC with millisecond precision and trailing zeros trimmed, as Go's RFC3339Nano renders it: whole
    /// seconds are `2026-06-10T12:00:00Z`. Fractional seconds keep two requests in the same second from colliding in the
    /// relay's replay cache (§4.1).
    public static func timestamp(_ t: Date) -> String {
        let millis = Timestamps.formatMillis(t) // "…:SS.mmmZ", ASCII digits in every locale
        let base = millis.prefix(19)
        var frac = String(millis.dropFirst(20).dropLast())
        while frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? base + "Z" : base + "." + frac + "Z"
    }

    /// The signed-request headers for one attempt; the timestamp header is signed verbatim.
    public static func headers(
        _ key: Ed25519PrivateKey, method: String, path: String, at t: Date, bodyHash: [UInt8]
    ) throws -> [String: String] {
        let ts = timestamp(t)
        return [
            headerKey: encodeKey(key.publicKey),
            headerTimestamp: ts,
            headerSig: Base64s.encodeStd(try signRequest(key, method: method, path: path, timestamp: ts, bodyHash: bodyHash)),
        ]
    }

    /// ASCII upper case only (never a locale's rules: "i" stays "I" in Turkish too).
    private static func upperASCII(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { (0x61...0x7A).contains($0.value) ? Unicode.Scalar($0.value - 32)! : $0 }))
    }
}
