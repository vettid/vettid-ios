import CMLKEM
import Foundation

/// SHA-3 (FIPS 202) from the vendored mlkem-native: what X-Wing needs, and nothing else uses.
enum SHA3 {
    static func shake256(_ input: [UInt8], outputLength: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: outputLength)
        vettid_shake256(&out, outputLength, input, input.count)
        return out
    }

    static func sha3_256(_ parts: [UInt8]...) -> [UInt8] {
        let input = parts.flatMap { $0 }
        var out = [UInt8](repeating: 0, count: 32)
        vettid_sha3_256(&out, input, input.count)
        return out
    }
}

/// ML-KEM-768 (FIPS 203) from the vendored mlkem-native, with the caller's randomness.
enum MLKEM768 {
    static let publicKeySize = Int(VETTID_MLKEM768_PUBLICKEYBYTES) // 1184
    static let secretKeySize = Int(VETTID_MLKEM768_SECRETKEYBYTES) // 2400
    static let ciphertextSize = Int(VETTID_MLKEM768_CIPHERTEXTBYTES) // 1088

    /// KeyGen_internal(d = coins[0:32], z = coins[32:64]).
    static func keypair(coins: [UInt8]) throws -> (pk: [UInt8], sk: [UInt8]) {
        guard coins.count == 64 else { throw CryptoError.key("ml-kem coins") }
        var pk = [UInt8](repeating: 0, count: publicKeySize)
        var sk = [UInt8](repeating: 0, count: secretKeySize)
        guard vettid_mlkem768_keypair_derand(&pk, &sk, coins) == 0 else { throw CryptoError.key("ml-kem keygen") }
        return (pk, sk)
    }

    /// Encaps_internal(pk, m): fails when pk does not pass the FIPS 203 modulus check.
    static func encapsulate(pk: [UInt8], m: [UInt8]) throws -> (ct: [UInt8], ss: [UInt8]) {
        guard pk.count == publicKeySize, m.count == 32 else { throw CryptoError.key("ml-kem encaps") }
        var ct = [UInt8](repeating: 0, count: ciphertextSize)
        var ss = [UInt8](repeating: 0, count: 32)
        guard vettid_mlkem768_enc_derand(&ct, &ss, pk, m) == 0 else { throw CryptoError.key("ml-kem ek") }
        return (ct, ss)
    }

    /// Decaps(sk, ct) with implicit rejection: a forged ciphertext gives an unrelated secret, not an error.
    static func decapsulate(sk: [UInt8], ct: [UInt8]) throws -> [UInt8] {
        guard sk.count == secretKeySize, ct.count == ciphertextSize else { throw CryptoError.decrypt }
        var ss = [UInt8](repeating: 0, count: 32)
        guard vettid_mlkem768_dec(&ss, ct, sk) == 0 else { throw CryptoError.key("ml-kem dk") }
        return ss
    }

    /// The FIPS 203 §7.2 modulus check: every coefficient below q (the encoding is canonical), as Go's
    /// `mlkem.NewEncapsulationKey768` and Android's `mlkemKeyIsCanonical` require.
    static func isCanonical(pk: [UInt8]) -> Bool {
        pk.count == publicKeySize && vettid_mlkem768_check_pk(pk) == 0
    }
}

/// X-Wing (draft-connolly-cfrg-xwing-kem; the MLKEM768X25519 KEM 0x647a of draft-ietf-hpke-pq): ML-KEM-768 and
/// X25519 under a SHA3-256 combiner. Keys come from a 32-byte seed expanded with SHAKE256.
enum XWing {
    static let seedSize = 32
    static let encapsulationRandomnessSize = 64
    /// `\.//^\`, the combiner's label.
    static let label: [UInt8] = [0x5C, 0x2E, 0x2F, 0x2F, 0x5E, 0x5C]

    struct Expanded {
        var mlkemSK: [UInt8]
        var x25519SK: [UInt8]
        let publicKey: [UInt8] // pk_M (1184) || pk_X (32)
    }

    /// expanded = SHAKE256(seed, 96); (pk_M, sk_M) = ML-KEM.KeyGen_internal(expanded[0:32], expanded[32:64]);
    /// sk_X = expanded[64:96]; pk = pk_M || X25519(sk_X, 9).
    static func expand(seed: [UInt8]) throws -> Expanded {
        guard seed.count == seedSize else { throw CryptoError.key("seed size") }
        var e = SHA3.shake256(seed, outputLength: 96)
        defer { Bytes.wipe(&e) }
        let (pkM, skM) = try MLKEM768.keypair(coins: Array(e[0..<64]))
        let skX = Array(e[64..<96])
        return Expanded(mlkemSK: skM, x25519SK: skX, publicKey: pkM + (try X25519.publicKey(skX)))
    }

    /// Encapsulates to [publicKey] with [randomness] (64 bytes: [0:32] ML-KEM `m`, [32:64] the X25519 ephemeral
    /// secret). Returns ct = ct_M || ct_X (1,120 bytes) and the shared secret.
    static func encapsulate(publicKey: [UInt8], randomness: [UInt8]) throws -> (enc: [UInt8], ss: [UInt8]) {
        guard publicKey.count == Suite.ekSize, randomness.count == encapsulationRandomnessSize else {
            throw CryptoError.key("x-wing encaps")
        }
        let pkM = Array(publicKey[0..<MLKEM768.publicKeySize])
        let pkX = Array(publicKey[MLKEM768.publicKeySize...])
        let encapsulated = try MLKEM768.encapsulate(pk: pkM, m: Array(randomness[0..<32]))
        var ssM = encapsulated.ss
        var ekX = Array(randomness[32..<64])
        defer {
            Bytes.wipe(&ssM)
            Bytes.wipe(&ekX)
        }
        let ctX = try X25519.publicKey(ekX)
        var ssX = try X25519.sharedSecret(ekX, pkX)
        defer { Bytes.wipe(&ssX) }
        return (encapsulated.ct + ctX, combine(ssM: ssM, ssX: ssX, ctX: ctX, pkX: pkX))
    }

    /// Decapsulates ct = ct_M || ct_X with the expanded key.
    static func decapsulate(_ key: Expanded, enc: [UInt8]) throws -> [UInt8] {
        guard enc.count == Suite.encSize else { throw CryptoError.key("enc size") }
        let ctM = Array(enc[0..<MLKEM768.ciphertextSize])
        let ctX = Array(enc[MLKEM768.ciphertextSize...])
        var ssM = try MLKEM768.decapsulate(sk: key.mlkemSK, ct: ctM)
        defer { Bytes.wipe(&ssM) }
        // An X25519 point that gives the all-zero secret is refused, as Go's crypto/ecdh refuses it.
        guard var ssX = try? X25519.sharedSecret(key.x25519SK, ctX) else { throw CryptoError.decrypt }
        defer { Bytes.wipe(&ssX) }
        let pkX = Array(key.publicKey[MLKEM768.publicKeySize...])
        return combine(ssM: ssM, ssX: ssX, ctX: ctX, pkX: pkX)
    }

    /// ss = SHA3-256(ss_M || ss_X || ct_X || pk_X || label).
    static func combine(ssM: [UInt8], ssX: [UInt8], ctX: [UInt8], pkX: [UInt8]) -> [UInt8] {
        SHA3.sha3_256(ssM, ssX, ctX, pkX, label)
    }
}

/// An MLKEM768X25519 encapsulation key `ek` (1,216 bytes, §3.2), validated. Mirrors vettid-android `KemPublicKey`.
public struct KemPublicKey: Hashable, Sendable, CustomStringConvertible {
    private let raw: [UInt8]

    /// The key's kid (§4.4).
    public let kid: Kid

    private init(checked raw: [UInt8]) {
        self.raw = raw
        kid = Kid.of(raw)
    }

    public var bytes: [UInt8] { raw }

    /// Constant-time comparison.
    public static func == (lhs: KemPublicKey, rhs: KemPublicKey) -> Bool { Bytes.constantTimeEquals(lhs.raw, rhs.raw) }

    public func hash(into hasher: inout Hasher) { hasher.combine(raw) }

    public var description: String { "KemPublicKey(kid=\(kid))" }

    /// Parses a 1,216-byte encapsulation key; rejects non-canonical ML-KEM encodings.
    public static func parse(_ ek: [UInt8]) throws -> KemPublicKey {
        guard ek.count == Suite.ekSize else { throw CryptoError.key("ek size") }
        guard MLKEM768.isCanonical(pk: Array(ek[0..<MLKEM768.publicKeySize])) else { throw CryptoError.key("ek not canonical") }
        return KemPublicKey(checked: ek)
    }
}

/// An MLKEM768X25519 decapsulation key, stored as its 32-byte seed (§3.2): the RFC 9180 serialized private key,
/// expanded with SHAKE256 as in X-Wing. ``destroy()`` wipes the seed and the expanded key. Mirrors vettid-android
/// `KemPrivateKey`.
public final class KemPrivateKey: @unchecked Sendable, CustomStringConvertible {
    private let lock = NSLock()
    private var seedBytes: [UInt8]?
    private var expanded: XWing.Expanded?

    /// The encapsulation key.
    public let publicKey: KemPublicKey

    private init(seed: [UInt8]) throws {
        let e = try XWing.expand(seed: seed)
        publicKey = try KemPublicKey.parse(e.publicKey)
        seedBytes = seed
        expanded = e
    }

    deinit { destroy() }

    func expandedKey() throws -> XWing.Expanded {
        try lock.withLock {
            guard let e = expanded else { throw CryptoError.key("destroyed") }
            return e
        }
    }

    /// A copy of the seed, for wrapped storage. Wipe it after use.
    public func seed() throws -> [UInt8] {
        try lock.withLock {
            guard let s = seedBytes else { throw CryptoError.key("destroyed") }
            return s
        }
    }

    public func destroy() {
        lock.withLock {
            if var s = seedBytes { Bytes.wipe(&s) }
            if var e = expanded {
                Bytes.wipe(&e.mlkemSK)
                Bytes.wipe(&e.x25519SK)
            }
            seedBytes = nil
            expanded = nil
        }
    }

    public var description: String { "KemPrivateKey(kid=\(publicKey.kid), [redacted])" }

    public static func fromSeed(_ seed: [UInt8]) throws -> KemPrivateKey {
        guard seed.count == Suite.seedSize else { throw CryptoError.key("seed size") }
        return try KemPrivateKey(seed: seed)
    }

    /// A new key pair from a fresh random seed.
    public static func generate() throws -> KemPrivateKey {
        var s = Randomness.bytes(Suite.seedSize)
        defer { Bytes.wipe(&s) }
        return try KemPrivateKey(seed: s)
    }
}
