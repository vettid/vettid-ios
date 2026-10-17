import Clibsodium
import CryptoKit
import Foundation

/// libsodium is initialised once, before its first use.
enum Sodium {
    static let ready: Bool = sodium_init() >= 0

    static func require() {
        precondition(ready, "libsodium failed to initialise")
    }
}

/// Ed25519 (RFC 8032) for identity keys, relay keys and the credential key. Every suite 2 signature is over
/// `label || message` (§13.4). libsodium, whose signatures are deterministic (IOS-PLAN ID6) and whose verification
/// refuses non-canonical `S` and small-order points. Mirrors vettid-android `Ed25519`.
public enum Ed25519 {
    public static let seedSize = 32

    /// Checks an Ed25519 signature over label || msg.
    public static func verify(_ publicKey: [UInt8], label: String, _ msg: [UInt8], _ sig: [UInt8]) -> Bool {
        verifyRaw(publicKey, Array(label.utf8) + msg, sig)
    }

    /// Checks an Ed25519 signature over [msg] (no label).
    public static func verifyRaw(_ publicKey: [UInt8], _ msg: [UInt8], _ sig: [UInt8]) -> Bool {
        guard publicKey.count == Suite.ed25519PublicSize, sig.count == Suite.ed25519SignatureSize else { return false }
        Sodium.require()
        return crypto_sign_verify_detached(sig, msg, UInt64(msg.count), publicKey) == 0
    }

    /// Throws unless the signature verifies.
    public static func requireValid(_ publicKey: [UInt8], label: String, _ msg: [UInt8], _ sig: [UInt8], what: String) throws {
        guard verify(publicKey, label: label, msg, sig) else { throw CryptoError.signature(what) }
    }

    /// Compares two public keys in constant time.
    public static func equalPublic(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a, let b, a.count == Suite.ed25519PublicSize, b.count == Suite.ed25519PublicSize else { return false }
        return Bytes.constantTimeEquals(a, b)
    }
}

/// An Ed25519 private key held as its 32-byte seed. ``destroy()`` wipes it. Keys kept on the phone wrap this seed
/// (VettIDKeys); the seed itself is never written anywhere in the clear. Mirrors vettid-android `Ed25519PrivateKey`.
public final class Ed25519PrivateKey: @unchecked Sendable, CustomStringConvertible {
    private let lock = NSLock()
    private var seedBytes: [UInt8]?

    /// The 32-byte public key.
    public let publicKey: [UInt8]

    private init(seed: [UInt8]) {
        Sodium.require()
        var pk = [UInt8](repeating: 0, count: Int(crypto_sign_PUBLICKEYBYTES))
        var sk = [UInt8](repeating: 0, count: Int(crypto_sign_SECRETKEYBYTES))
        crypto_sign_seed_keypair(&pk, &sk, seed)
        Bytes.wipe(&sk)
        publicKey = pk
        seedBytes = seed
    }

    deinit {
        if var s = seedBytes { Bytes.wipe(&s) }
    }

    /// Ed25519(seed, label || msg). Deterministic.
    public func sign(label: String, _ msg: [UInt8]) throws -> [UInt8] {
        try signRaw(Array(label.utf8) + msg)
    }

    /// Ed25519(seed, msg) without a label (only where the spec signs a full string, e.g. §11.4).
    public func signRaw(_ msg: [UInt8]) throws -> [UInt8] {
        try lock.withLock {
            guard let seed = seedBytes else { throw CryptoError.key("destroyed") }
            var pk = [UInt8](repeating: 0, count: Int(crypto_sign_PUBLICKEYBYTES))
            var sk = [UInt8](repeating: 0, count: Int(crypto_sign_SECRETKEYBYTES))
            defer { Bytes.wipe(&sk) }
            crypto_sign_seed_keypair(&pk, &sk, seed)
            var sig = [UInt8](repeating: 0, count: Suite.ed25519SignatureSize)
            crypto_sign_detached(&sig, nil, msg, UInt64(msg.count), sk)
            return sig
        }
    }

    /// A copy of the seed, for wrapping by the key store. Wipe it after use.
    public func seed() throws -> [UInt8] {
        try lock.withLock {
            guard let seed = seedBytes else { throw CryptoError.key("destroyed") }
            return seed
        }
    }

    public func destroy() {
        lock.withLock {
            if var s = seedBytes { Bytes.wipe(&s) }
            seedBytes = nil
        }
    }

    public var description: String { "Ed25519PrivateKey[redacted]" }

    /// Derives a key from a 32-byte seed (copied).
    public static func fromSeed(_ seed: [UInt8]) throws -> Ed25519PrivateKey {
        guard seed.count == Ed25519.seedSize else { throw CryptoError.key("seed size") }
        return Ed25519PrivateKey(seed: seed)
    }

    /// Generates a key from ``Randomness``.
    public static func generate() -> Ed25519PrivateKey {
        var s = Randomness.bytes(Ed25519.seedSize)
        defer { Bytes.wipe(&s) }
        return Ed25519PrivateKey(seed: s)
    }
}

/// X25519 (RFC 7748) through CryptoKit: the classical half of the X-Wing KEM (§4.3) and nothing else.
public enum X25519 {
    public static let keySize = 32

    /// The public key of a 32-byte private scalar.
    public static func publicKey(_ privateKey: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == keySize,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        else { throw CryptoError.key("x25519 private key") }
        return Array(key.publicKey.rawRepresentation)
    }

    /// The shared secret X25519(privateKey, publicKey); refuses the all-zero output of a small-order public key.
    public static func sharedSecret(_ privateKey: [UInt8], _ publicKey: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == keySize, publicKey.count == keySize,
              let sk = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
              let pk = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey),
              let shared = try? sk.sharedSecretFromKeyAgreement(with: pk)
        else { throw CryptoError.key("x25519") }
        let out = shared.withUnsafeBytes { Array($0) }
        guard !Bytes.constantTimeEquals(out, [UInt8](repeating: 0, count: keySize)) else { throw CryptoError.key("x25519 low order") }
        return out
    }
}
