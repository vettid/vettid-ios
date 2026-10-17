/// Every failure of the protocol code. Messages are fixed strings naming the kind of failure; they never carry input
/// bytes, plaintext or key material. Mirrors vettid-android `CryptoException`.
public enum CryptoError: Error, Equatable, CustomStringConvertible {
    /// Malformed input (wire format, JSON, sizes, encodings).
    case format(String)
    /// Wrong key size, invalid key, or a destroyed key.
    case key(String)
    /// An AEAD or HPKE open failed.
    case decrypt
    /// A signature did not verify.
    case signature(String)
    /// Suite negotiation failures (VAULT-MESSAGING §4.1, §13.4).
    case suite(String)
    /// A protocol rule was violated (sender, kid, purpose, state).
    case protocolViolation(String)
    /// A message failed its freshness rules (§5.3, §8.4).
    case time(String)
    /// An HPKE context or handshake was used after it was spent.
    case used(String)
    /// A genuine message of an epoch that is not established yet (§6.3): leave it for redelivery.
    case early(String)

    public var description: String {
        switch self {
        case .format(let what): "malformed: \(what)"
        case .key(let what): "key: \(what)"
        case .decrypt: "decryption failed"
        case .signature(let what): "signature: \(what)"
        case .suite(let what): "suite: \(what)"
        case .protocolViolation(let what): "protocol: \(what)"
        case .time(let what): "time: \(what)"
        case .used(let what): "already used: \(what)"
        case .early(let what): "not yet: \(what)"
        }
    }

    /// The kind of failure, without its detail (for tests and callers that only branch on the kind).
    public enum Kind: Sendable { case format, key, decrypt, signature, suite, protocolViolation, time, used, early }

    public var kind: Kind {
        switch self {
        case .format: .format
        case .key: .key
        case .decrypt: .decrypt
        case .signature: .signature
        case .suite: .suite
        case .protocolViolation: .protocolViolation
        case .time: .time
        case .used: .used
        case .early: .early
        }
    }
}
