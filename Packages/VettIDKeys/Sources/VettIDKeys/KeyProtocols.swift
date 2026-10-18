import CryptoKit
import Foundation
import VettIDCrypto

// The keys behind protocols (IOS-PLAN §6.1): the Secure Enclave and App Attest on the iPhone (SecureEnclaveKeys.swift,
// AppAttest.swift), software keys of VettIDKeysTesting in tests and on the simulator. Every implementation is
// nonisolated and Sendable, and its errors are ``KeysError``s that never carry key material. Mirrors vettid-android
// `:core:keystore` (`AppApiKey`, `PhoneKeyHandle`, `SeedWrapKey`).

/// The app key (VAULT-MESSAGING §11.12.2): a P-256 signing key that signs every app request to the member API. On the
/// iPhone a Secure Enclave key with `.privateKeyUsage` only, `AfterFirstUnlockThisDeviceOnly`, so that a lock and the
/// result polling work in the background.
public protocol AppSigningKey: Sendable {
    /// The public key's SubjectPublicKeyInfo DER.
    func spki() throws -> [UInt8]

    /// ECDSA P-256 with SHA-256 over [message], DER-encoded.
    func sign(_ message: [UInt8]) throws -> [UInt8]
}

extension AppSigningKey {
    /// `akid`: the first 16 bytes of SHA-256(SPKI DER), 32 lowercase hex (§11.12.2).
    public func akid() throws -> String { AppKeyID.akid(try spki()) }
}

/// The app key's id (§11.12.2).
public enum AppKeyID {
    public static let size = 16

    public static func akid(_ spki: [UInt8]) -> String { Bytes.hex(Array(Bytes.sha256(spki).prefix(size))) }
}

/// Where the app key lives: one per vault, made at a setup, a recovery or a transfer to this phone. Mirrors
/// vettid-android `AppApiKey`.
public protocol AppKeyStore: KeyEraser {
    /// The key, made when there is none ("no such item" only; a locked lookup throws ``KeysError/unavailable(_:)``).
    func getOrCreate() throws -> any AppSigningKey

    /// A fresh key (an existing one is replaced).
    func regenerate() throws -> any AppSigningKey

    /// The key if there is one, classified by IOS-PLAN §6.3.
    func lookup() -> ItemLookup<any AppSigningKey>
}

/// A P-256 key-agreement key held by the hardware: the phone key `P` (VAULT-MESSAGING §11.14.1 "On an iPhone") or the
/// seed-wrapping key (IOS-PLAN §6.1).
public protocol KeyAgreementKey: Sendable {
    /// The public key, SEC1 uncompressed (65 bytes, CryptoKit's `x963Representation`).
    func publicKey() throws -> [UInt8]

    /// ECDH with [peer] (SEC1 uncompressed, parsed with full point validation): the x-coordinate of the shared point,
    /// 32 bytes, big-endian. Throws ``KeysError/unavailable(_:)`` while the iPhone is locked (the phone key's class is
    /// `WhenUnlockedThisDeviceOnly`) and ``KeysError/invalid(_:)`` when iOS reports the key invalid.
    func agree(_ peer: [UInt8]) throws -> [UInt8]
}

/// The phone key's source. Each key is made for a `key_vault` (the vault id, or "" for a key made at a transfer to this
/// phone; fixed for the key's life) and gets its own random key id: its keychain label names both
/// (``PhoneKeyLabel``), and the records name the exact key they need. A new key never overwrites an existing one, so a
/// key the vault may still hold the secret of is deleted only once no kept record names it (chosen; not in the spec:
/// IOS-PLAN §6.3 binds the label to `key_vault`, the key id is added to it). On the iPhone a Secure Enclave
/// key-agreement key with `.privateKeyUsage` only, `WhenUnlockedThisDeviceOnly`; the software one exists only in
/// VettIDKeysTesting (IOS-PLAN §6.3, "No software phone key in Release or Staging builds"). Mirrors vettid-android
/// `PhoneKeyHandle`.
///
/// **Invariant:** a source serves exactly one records file (VettIDData's `PhoneSecrets` enforces it process-wide by
/// ``sourceID``), so every key it holds is named, if at all, by that file; a damaged file's replacement may then delete
/// the keys nothing names.
public protocol PhoneSecretSource: KeyEraser {
    /// The source's identity, the same for every instance over the same keys (on the iPhone the keychain service and
    /// the label prefix).
    var sourceID: String { get }

    /// Makes a new key for [keyVault] under a fresh key id, beside every existing key. Throws
    /// ``KeysError/noSecureHardware`` where the hardware cannot hold it.
    func create(keyVault: String) throws -> (keyID: String, key: any KeyAgreementKey)

    /// The key [keyID] of [keyVault], classified by IOS-PLAN §6.3.
    func lookup(keyVault: String, keyID: String) -> ItemLookup<any KeyAgreementKey>

    /// Removes the key [keyID] of [keyVault].
    func delete(keyVault: String, keyID: String) throws

    /// Every phone key this source holds (to delete those no record names after a damaged records file is replaced).
    func keyNames() throws -> [PhoneKeyName]
}

/// A phone key's name: the `key_vault` it was made for and its key id.
public struct PhoneKeyName: Hashable, Sendable {
    public let keyVault: String
    public let keyID: String

    public init(keyVault: String, keyID: String) {
        self.keyVault = keyVault
        self.keyID = keyID
    }
}

/// The keychain label of a phone key: `vettid.phone.v1` ‖ 0x1F ‖ key_vault ‖ 0x1F ‖ key id, so that it names the
/// `key_vault` the key was made for (IOS-PLAN §6.3) and the instance (chosen; not in the spec). Vault ids are ASCII
/// without control characters.
public enum PhoneKeyLabel {
    public static let prefix = "vettid.phone.v1"
    public static let keyIDSize = 16

    public static func make(keyVault: String, keyID: String) -> String { [prefix, keyVault, keyID].joined(separator: "\u{1F}") }

    /// A fresh key id: 16 random bytes, lowercase hex.
    public static func newKeyID() -> String { Bytes.hex(Randomness.bytes(keyIDSize)) }
}

/// Something that removes every key or item of its kind: the first-run cleanup (IOS-PLAN §6.1) and a wipe.
public protocol KeyEraser: Sendable {
    func deleteAll() throws
}

/// ECDH of a software key with a stored public key, for the software stand-ins and the two-way checks.
public enum SoftwareECDH {
    /// [peer] parsed with full point validation (65-byte SEC1 uncompressed, on the curve).
    public static func publicKey(_ peer: [UInt8]) throws -> P256.KeyAgreement.PublicKey {
        do {
            return try PhoneSecretIOS.publicKey(peer)
        } catch {
            throw KeysError.invalid("peer point")
        }
    }

    /// The x-coordinate of priv·peer, 32 bytes.
    public static func agree(_ privateKey: P256.KeyAgreement.PrivateKey, _ peer: [UInt8]) throws -> [UInt8] {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: try publicKey(peer))
        return shared.withUnsafeBytes { Array($0) }
    }
}
