import CryptoKit
import Foundation

/// RFC 9180 Export.
public protocol HpkeExporter: Sendable {
    func export(_ label: String, _ length: Int) throws -> [UInt8]
}

/// Suite 2 HPKE (RFC 9180, base mode): KEM MLKEM768X25519 (0x647a, X-Wing), KDF HKDF-SHA256, AEAD ChaCha20-Poly1305,
/// byte for byte as Go 1.26 `crypto/hpke` and vettid-android: the §16 vectors pin the encapsulation key, the
/// encapsulated key, the key schedule and every sealed byte. Mirrors vettid-android `Hpke`.
enum Hpke {
    /// HPKE encapsulation randomness: [0:32] ML-KEM `m`, [32:64] the X25519 ephemeral secret.
    static let randomnessSize = XWing.encapsulationRandomnessSize

    private static let nonceSize = 12
    private static let version = Array("HPKE-v1".utf8)
    static let suiteID: [UInt8] = Array("HPKE".utf8) + Bytes.uintBE(UInt64(Suite.kemID), 2) +
        Bytes.uintBE(UInt64(Suite.kdfID), 2) + Bytes.uintBE(UInt64(Suite.aeadID), 2)

    static func labeledExtract(salt: [UInt8], label: String, ikm: [UInt8]) -> [UInt8] {
        Hkdf.extract(salt: salt, ikm: version + suiteID + Array(label.utf8) + ikm)
    }

    static func labeledExpand(prk: [UInt8], label: String, info: [UInt8], length: Int) throws -> [UInt8] {
        try Hkdf.expand(
            prk: prk,
            info: Bytes.uintBE(UInt64(length), 2) + version + suiteID + Array(label.utf8) + info,
            length: length
        )
    }

    /// The base-mode key schedule (RFC 9180 §5.1, empty PSK).
    struct Schedule {
        var key: [UInt8]
        var baseNonce: [UInt8]
        var exporterSecret: [UInt8]

        init(sharedSecret: [UInt8], info: [UInt8]) throws {
            let context = [0x00] + // mode_base
                Hpke.labeledExtract(salt: [], label: "psk_id_hash", ikm: []) +
                Hpke.labeledExtract(salt: [], label: "info_hash", ikm: info)
            var secret = Hpke.labeledExtract(salt: sharedSecret, label: "secret", ikm: [])
            defer { Bytes.wipe(&secret) }
            key = try Hpke.labeledExpand(prk: secret, label: "key", info: context, length: Suite.keySize)
            baseNonce = try Hpke.labeledExpand(prk: secret, label: "base_nonce", info: context, length: Hpke.nonceSize)
            exporterSecret = try Hpke.labeledExpand(prk: secret, label: "exp", info: context, length: Suite.hashSize)
        }

        func export(_ label: String, _ length: Int) throws -> [UInt8] {
            try Hpke.labeledExpand(prk: exporterSecret, label: "sec", info: Array(label.utf8), length: length)
        }

        /// Seq 0 is the only one: a context seals or opens one message (§4.3).
        func seal(aad: [UInt8], plaintext: [UInt8]) throws -> [UInt8] {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: ChaChaPoly.Nonce(data: baseNonce),
                authenticating: aad
            )
            return Array(box.ciphertext) + Array(box.tag)
        }

        func open(aad: [UInt8], ciphertext: [UInt8]) throws -> [UInt8] {
            guard ciphertext.count >= Suite.tagSize else { throw CryptoError.decrypt }
            do {
                let box = try ChaChaPoly.SealedBox(
                    nonce: ChaChaPoly.Nonce(data: baseNonce),
                    ciphertext: ciphertext.prefix(ciphertext.count - Suite.tagSize),
                    tag: ciphertext.suffix(Suite.tagSize)
                )
                return Array(try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad))
            } catch {
                throw CryptoError.decrypt
            }
        }

        mutating func wipe() {
            Bytes.wipe(&key)
            Bytes.wipe(&baseNonce)
            Bytes.wipe(&exporterSecret)
        }
    }
}

/// A one-shot flag: the first ``claim()`` succeeds, every later one throws.
private final class SingleUse: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() throws {
        try lock.withLock {
            if used { throw CryptoError.used("hpke context") }
            used = true
        }
    }
}

/// A sending context (SetupBaseS). It seals exactly one message (§4.3: a context MUST NOT be reused) and may export
/// any number of secrets. Mirrors vettid-android `HpkeSender`.
public final class HpkeSender: HpkeExporter, @unchecked Sendable {
    private let schedule: Hpke.Schedule
    private let once = SingleUse()

    /// The encapsulated key (1,120 bytes).
    public let enc: [UInt8]

    private init(schedule: Hpke.Schedule, enc: [UInt8]) {
        self.schedule = schedule
        self.enc = enc
    }

    public func seal(aad: [UInt8], plaintext: [UInt8]) throws -> [UInt8] {
        try once.claim()
        return try schedule.seal(aad: aad, plaintext: plaintext)
    }

    public func export(_ label: String, _ length: Int) throws -> [UInt8] { try schedule.export(label, length) }

    /// SetupBaseS(pk_R = [recipient], [info]) with randomness from ``Randomness``.
    public static func setup(_ recipient: KemPublicKey, info: [UInt8]) throws -> HpkeSender {
        var rnd = Randomness.bytes(Hpke.randomnessSize)
        defer { Bytes.wipe(&rnd) }
        var (enc, ss) = try XWing.encapsulate(publicKey: recipient.bytes, randomness: rnd)
        defer { Bytes.wipe(&ss) }
        guard enc.count == Suite.encSize else {
            Bytes.wipe(&enc)
            throw CryptoError.key("enc size")
        }
        return HpkeSender(schedule: try Hpke.Schedule(sharedSecret: ss, info: info), enc: enc)
    }

    #if DEBUG
    /// TEST ONLY (debug builds): a sender with its shared secret and key schedule, for the §16 vectors.
    struct Exposed {
        let sender: HpkeSender
        let sharedSecret: [UInt8]
        let schedule: Hpke.Schedule
    }

    /// TEST ONLY (debug builds): ``setup(_:info:)`` that also returns the values the §16 vectors pin.
    static func setupExposingSchedule(_ recipient: KemPublicKey, info: [UInt8]) throws -> Exposed {
        let rnd = Randomness.bytes(Hpke.randomnessSize)
        let (enc, ss) = try XWing.encapsulate(publicKey: recipient.bytes, randomness: rnd)
        let schedule = try Hpke.Schedule(sharedSecret: ss, info: info)
        return Exposed(sender: HpkeSender(schedule: schedule, enc: enc), sharedSecret: ss, schedule: schedule)
    }
    #endif
}

/// A receiving context (SetupBaseR). It opens exactly one message. Mirrors vettid-android `HpkeRecipient`.
public final class HpkeRecipient: HpkeExporter, @unchecked Sendable {
    private let schedule: Hpke.Schedule
    private let once = SingleUse()

    private init(schedule: Hpke.Schedule) { self.schedule = schedule }

    public func open(aad: [UInt8], ciphertext: [UInt8]) throws -> [UInt8] {
        try once.claim()
        return try schedule.open(aad: aad, ciphertext: ciphertext)
    }

    public func export(_ label: String, _ length: Int) throws -> [UInt8] { try schedule.export(label, length) }

    /// SetupBaseR(enc, sk_R, info).
    public static func setup(enc: [UInt8], key: KemPrivateKey, info: [UInt8]) throws -> HpkeRecipient {
        guard enc.count == Suite.encSize else { throw CryptoError.key("enc size") }
        var ss = try XWing.decapsulate(key.expandedKey(), enc: enc)
        defer { Bytes.wipe(&ss) }
        return HpkeRecipient(schedule: try Hpke.Schedule(sharedSecret: ss, info: info))
    }
}
