import CryptoKit
import Foundation
import VettIDCrypto

/// `0x01 || iv (12) || AES-256-GCM(key, iv, aad, plaintext) || tag (16)`: the format of vettid-android's wrapped seeds
/// and encrypted files (the Java cipher appends the tag to the ciphertext), shared by ``SeedWrapper`` and
/// ``EncryptedFileStore``.
public enum AesGcmBlob {
    public static let format: UInt8 = 0x01
    public static let ivSize = 12
    public static let tagSize = 16
    public static let overhead = 1 + ivSize + tagSize

    public static func seal(_ key: SymmetricKey, aad: [UInt8], _ plaintext: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
        return [format] + Array(box.nonce) + Array(box.ciphertext) + Array(box.tag)
    }

    /// Opens a blob made by ``seal(_:aad:_:)``; [what] names the item in the error. Another format byte is
    /// ``KeysError/unknownFormat(_:)``; a short blob or a failed tag is ``KeysError/corrupt(_:)``.
    public static func open(_ key: SymmetricKey, aad: [UInt8], _ blob: [UInt8], what: String) throws -> [UInt8] {
        guard let first = blob.first else { throw KeysError.corrupt(what) }
        guard first == format else { throw KeysError.unknownFormat(what) }
        guard blob.count >= overhead else { throw KeysError.corrupt(what) }
        var plain: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: blob[1 ..< 1 + ivSize]),
                ciphertext: blob[(1 + ivSize) ..< (blob.count - tagSize)],
                tag: blob[(blob.count - tagSize)...]
            )
            plain = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw KeysError.corrupt(what)
        }
        defer { plain.resetBytes(in: 0 ..< plain.count) }
        return Array(plain)
    }
}

/// Where the seed-wrapping key lives: on the iPhone a Secure Enclave P-256 key-agreement key with `.privateKeyUsage`
/// only, its blob in the keychain `AfterFirstUnlockThisDeviceOnly` (the relay key must work in the background).
public protocol SeedWrapKeySource: KeyEraser {
    func getOrCreate() throws -> any KeyAgreementKey
}

/// Wraps the app's device private keys (relay key, identity key `ik`, static KEM key, each held as a 32-byte seed) under
/// a key derived from a hardware key agreement (VAULT-MESSAGING §3.2: "If a platform keystore cannot hold them natively,
/// they MUST be stored encrypted under a key that the keystore holds"; IOS-PLAN §6.1). The Secure Enclave holds no AES
/// keys, so the wrapping key is
///
/// ```
/// wrap_key = HKDF-SHA-256(ikm = ECDH(priv(W), pub(W)), salt = empty, info = "vettid/ios/seed-wrap/1", L = 32)
/// ```
///
/// with `W` the seed-wrapping key-agreement key (chosen; IOS-PLAN §6.1 names only "a key derived from a Secure Enclave
/// key agreement"). The blob is vettid-android's format, ``AesGcmBlob`` with
/// `aad = "vettid/keystore/1" || 0x00 || slot`, so that a wrapped relay seed cannot be swapped in as the identity seed.
/// Mirrors vettid-android `SeedWrapper`.
public final class SeedWrapper: Sendable {
    public static let aadLabel = "vettid/keystore/1"
    public static let keyInfo = "vettid/ios/seed-wrap/1"

    private let key: @Sendable () throws -> any KeyAgreementKey

    public init(key: @escaping @Sendable () throws -> any KeyAgreementKey) {
        self.key = key
    }

    public convenience init(source: any SeedWrapKeySource) {
        self.init { try source.getOrCreate() }
    }

    /// Wraps [seed] for [slot].
    public func wrap(_ slot: KeySlot, _ seed: [UInt8]) throws -> [UInt8] {
        try AesGcmBlob.seal(try wrappingKey(), aad: Self.aad(slot), seed)
    }

    /// Unwraps a blob made by ``wrap(_:_:)`` for the same slot. The caller wipes the result.
    public func unwrap(_ slot: KeySlot, _ blob: [UInt8]) throws -> [UInt8] {
        try AesGcmBlob.open(try wrappingKey(), aad: Self.aad(slot), blob, what: "wrapped \(slot.rawValue) key")
    }

    public func unwrapEd25519(_ slot: KeySlot, _ blob: [UInt8]) throws -> Ed25519PrivateKey {
        var seed = try unwrap(slot, blob)
        defer { Bytes.wipe(&seed) }
        return try Ed25519PrivateKey.fromSeed(seed)
    }

    public func unwrapKem(_ slot: KeySlot, _ blob: [UInt8]) throws -> KemPrivateKey {
        var seed = try unwrap(slot, blob)
        defer { Bytes.wipe(&seed) }
        return try KemPrivateKey.fromSeed(seed)
    }

    private func wrappingKey() throws -> SymmetricKey {
        let k = try key()
        var z = try k.agree(try k.publicKey())
        defer { Bytes.wipe(&z) }
        var derived = try Hkdf.derive(ikm: z, salt: [], info: Array(Self.keyInfo.utf8), length: 32)
        defer { Bytes.wipe(&derived) }
        return SymmetricKey(data: derived)
    }

    static func aad(_ slot: KeySlot) -> [UInt8] { Array(aadLabel.utf8) + [0] + Array(slot.rawValue.utf8) }
}

/// The device keys the app wraps (VAULT-MESSAGING §3.2). Mirrors vettid-android `KeySlot`.
public enum KeySlot: String, CaseIterable, Sendable {
    /// The relay key (Ed25519): signs relay requests, mints tokens.
    case relay
    /// The identity key `ik` (Ed25519): signs handshakes and unlocks.
    case identity
    /// The static KEM key (MLKEM768X25519 seed): receives sealed messages.
    case kem
}

/// Where wrapped seeds are kept (ciphertext only). On the iPhone the keychain (``KeychainWrappedKeyStore``). Mirrors
/// vettid-android `WrappedKeyStore`.
public protocol WrappedKeyStore: KeyEraser {
    func get(_ slot: KeySlot) throws -> [UInt8]?
    func put(_ slot: KeySlot, _ blob: [UInt8]) throws
    func remove(_ slot: KeySlot) throws
}

extension WrappedKeyStore {
    public func deleteAll() throws {
        for slot in KeySlot.allCases { try remove(slot) }
    }
}

/// The app's device keys (§3.2): relay key and identity key (Ed25519) and the static KEM key, each generated from a fresh
/// random seed, stored only wrapped (``SeedWrapper``), and unwrapped on use. The three keys are distinct by construction
/// (independent seeds), as §3.2 requires. Mirrors vettid-android `DeviceKeys`.
public final class DeviceKeys: Sendable {
    private let wrapper: SeedWrapper
    private let store: any WrappedKeyStore

    public init(wrapper: SeedWrapper, store: any WrappedKeyStore) {
        self.wrapper = wrapper
        self.store = store
    }

    /// Generates and stores a new seed for [slot], replacing any existing one.
    public func generate(_ slot: KeySlot) throws {
        var seed: [UInt8]
        switch slot {
        case .kem:
            let k = try KemPrivateKey.generate()
            seed = try k.seed()
            k.destroy()
        case .relay, .identity:
            let k = Ed25519PrivateKey.generate()
            seed = try k.seed()
            k.destroy()
        }
        defer { Bytes.wipe(&seed) }
        try store.put(slot, try wrapper.wrap(slot, seed))
    }

    public func has(_ slot: KeySlot) throws -> Bool { try store.get(slot) != nil }

    /// The relay or identity key. The caller destroys it when done.
    public func ed25519(_ slot: KeySlot) throws -> Ed25519PrivateKey {
        precondition(slot != .kem)
        guard let blob = try store.get(slot) else { throw KeysError.missing("\(slot.rawValue) key") }
        return try wrapper.unwrapEd25519(slot, blob)
    }

    /// The static KEM key. The caller destroys it when done.
    public func kem() throws -> KemPrivateKey {
        guard let blob = try store.get(.kem) else { throw KeysError.missing("kem key") }
        return try wrapper.unwrapKem(.kem, blob)
    }

    /// Removes every device key (a wipe; a transfer away).
    public func clear() throws { try store.deleteAll() }
}
