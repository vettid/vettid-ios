/// An 8-byte key id (VAULT-MESSAGING §4.4). Kids are lookup hints, not authenticators; they are compared in constant
/// time anyway. Mirrors vettid-android `Kid`.
public struct Kid: Hashable, Sendable, CustomStringConvertible {
    private let b: [UInt8]

    public init(_ bytes: [UInt8]) throws {
        guard bytes.count == Suite.kidSize else { throw CryptoError.key("kid size") }
        b = bytes
    }

    /// For sizes this file has already checked.
    private init(checked bytes: [UInt8]) { b = bytes }

    public var bytes: [UInt8] { b }

    public var isAnonymous: Bool { Bytes.constantTimeEquals(b, [UInt8](repeating: 0, count: Suite.kidSize)) }

    public static func == (lhs: Kid, rhs: Kid) -> Bool { Bytes.constantTimeEquals(lhs.b, rhs.b) }

    public func hash(into hasher: inout Hasher) { hasher.combine(b) }

    /// Lowercase hex.
    public var description: String { Bytes.hex(b) }

    /// The all-zero kid of an anonymous sender.
    public static let anonymous = Kid(checked: [UInt8](repeating: 0, count: Suite.kidSize))

    /// SHA-256("vettid/vms/2/kid" || ek)[0:8], for a static KEM key or the ETK.
    public static func of(_ ek: [UInt8]) -> Kid {
        Kid(checked: Array(Bytes.labeledHash(Labels.kid, ek).prefix(Suite.kidSize)))
    }

    /// Parses 16 lowercase hex characters.
    public static func parseHex(_ s: String) throws -> Kid {
        guard Bytes.isLowerHex(s, 2 * Suite.kidSize) else { throw CryptoError.format("kid") }
        return try Kid(Bytes.unhex(s))
    }
}

/// The fingerprint of a vault's identity key (VAULT-MESSAGING 0.18.0 §10.8, vector in §16): what a connection's
/// details show for its pinned `ik`, identifying the peer's vault, not a person.
///
/// `fp = SHA-256("vettid/vms/2/ik-fp" || ik)`, `ik` the 32 raw bytes, shown as its first 16 bytes in lowercase hex,
/// in 8 groups of 4 digits separated by spaces. Mirrors vettid-android `IkFingerprint`.
public enum IkFingerprint {
    /// The identity key's size (an Ed25519 public key).
    public static let ikSize = 32
    private static let shownBytes = 16
    private static let group = 4

    /// The full SHA-256 fingerprint of [ik] (32 raw bytes).
    public static func digest(_ ik: [UInt8]) throws -> [UInt8] {
        guard ik.count == ikSize else { throw CryptoError.format("ik") }
        return Bytes.labeledHash(Labels.ikFP, ik)
    }

    /// The fingerprint as shown: `9a1f bb7d 873e eafb 494b ef94 f072 7b25`.
    public static func format(_ ik: [UInt8]) throws -> String {
        let hex = Array(Bytes.hex(Array(try digest(ik).prefix(shownBytes))))
        return stride(from: 0, to: hex.count, by: group).map { String(hex[$0..<$0 + group]) }.joined(separator: " ")
    }

    /// ``format(_:)`` of a standard-base64 `ik`; nil when it is not the base64 of 32 bytes.
    public static func formatB64(_ ikB64: String) -> String? {
        try? format(Base64s.decodeStd(ikB64, ikSize))
    }
}
