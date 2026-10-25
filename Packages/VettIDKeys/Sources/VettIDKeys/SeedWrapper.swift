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

/// One of the two device identities a phone holds (IOS-PLAN 0.1.33 §4.9): a phone that could not tell whether an open recovered
/// the vault registers a new identity for its new recovery and keeps the earlier one until the pairing completed. Its relay,
/// identity and KEM keys (``KeySlot/slots(of:)``) and its device state file are its own; the app key K is shared.
public struct IdentitySet: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    /// The most identities a phone holds at once: two (owner decision of 2026-10-25).
    public static let limit = 2
    public static let first = IdentitySet(rawValue: 0)
    public static let second = IdentitySet(rawValue: 1)
    public static var all: [IdentitySet] { (0..<limit).map { IdentitySet(rawValue: $0) } }

    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(Int.self) }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// The identity after this one (nil past ``limit``).
    public var next: IdentitySet? { rawValue + 1 < Self.limit ? IdentitySet(rawValue: rawValue + 1) : nil }

    public var description: String { "identity \(rawValue)" }
}

/// The device keys the app wraps (VAULT-MESSAGING §3.2), of one identity (``IdentitySet``). Mirrors vettid-android `KeySlot`.
public struct KeySlot: Hashable, Sendable, CustomStringConvertible {
    public enum Role: String, CaseIterable, Sendable {
        /// The relay key (Ed25519): signs relay requests, mints tokens.
        case relay
        /// The identity key `ik` (Ed25519): signs handshakes and unlocks.
        case identity
        /// The static KEM key (MLKEM768X25519 seed): receives sealed messages.
        case kem
    }

    public let role: Role
    public let index: Int

    public static let relay = KeySlot(.relay, 0)
    public static let identity = KeySlot(.identity, 0)
    public static let kem = KeySlot(.kem, 0)
    public static let relay2 = KeySlot(.relay, 1)
    public static let identity2 = KeySlot(.identity, 1)
    public static let kem2 = KeySlot(.kem, 1)

    public init(_ role: Role, _ index: Int) {
        self.role = role
        self.index = index
    }

    /// The name of the key (`relay`, `relay2`, …): also its keychain item and the AAD of its wrapped seed.
    public var rawValue: String { index == 0 ? role.rawValue : "\(role.rawValue)\(index + 1)" }

    public var description: String { rawValue }

    /// Every slot of every identity (a wipe removes them all).
    public static var allCases: [KeySlot] { IdentitySet.all.flatMap { slots(of: $0) } }

    /// The keys of one identity.
    public static func slots(of set: IdentitySet) -> [KeySlot] { Role.allCases.map { KeySlot($0, set.rawValue) } }

    /// This slot's key in [set]'s identity (`.relay` is `.relay2` in the second).
    public func of(_ set: IdentitySet) -> KeySlot { KeySlot(role, set.rawValue) }
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
        switch slot.role {
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
        precondition(slot.role != .kem)
        guard let blob = try store.get(slot) else { throw KeysError.missing("\(slot.rawValue) key") }
        return try wrapper.unwrapEd25519(slot, blob)
    }

    /// The static KEM key. The caller destroys it when done.
    public func kem(_ slot: KeySlot = .kem) throws -> KemPrivateKey {
        precondition(slot.role == .kem)
        guard let blob = try store.get(slot) else { throw KeysError.missing("kem key") }
        return try wrapper.unwrapKem(slot, blob)
    }

    /// Removes every device key (a wipe; a transfer away).
    public func clear() throws { try store.deleteAll() }
}
