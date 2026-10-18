import CryptoKit
import Foundation
import Security

// The Secure Enclave keys of IOS-PLAN §6.1 and §6.3 behind their protocols: the app key, the seed-wrapping key and the
// phone keys. Every key is `ThisDeviceOnly`, never synchronizable, with `.privateKeyUsage` only (never bound to biometry
// or the passcode); each source names its keys by its own application tag, so that a test's keys never touch the
// app's. Mirrors vettid-android `:core:keystore` (`AppApiKey`, `SeedWrapKey`, `PhoneKey`).

/// The app key in the Secure Enclave (VAULT-MESSAGING §11.12.2; IOS-PLAN §6.1): a P-256 signing key,
/// `AfterFirstUnlockThisDeviceOnly`, so that a lock and the result polling sign in the background while the iPhone is
/// locked after its first unlock. Mirrors vettid-android `AppApiKey`.
public final class SecureEnclaveAppKeyStore: AppKeyStore, @unchecked Sendable {
    public static let tag = "com.vettid.appkey.v1"
    static let what = "app key"

    private let keychain: SecureEnclaveKeychain
    private let lock = NSLock()

    /// [tag] names the key; tests pass their own (`vettid.test.…`) so they never touch the app's.
    public init(tag: String = SecureEnclaveAppKeyStore.tag, protectedData: any ProtectedData) {
        keychain = SecureEnclaveKeychain(tag: tag, accessible: .afterFirstUnlockThisDeviceOnly, protectedData: protectedData)
    }

    public func getOrCreate() throws -> any AppSigningKey {
        lock.lock()
        defer { lock.unlock() }
        switch keychain.lookup(nil) {
        case .found(let k): return key(k)
        case .unavailable: throw KeysError.unavailable(Self.what)
        case .missing:
            try keychain.delete(nil, what: Self.what)
            return key(try keychain.create(label: nil, what: Self.what))
        }
    }

    public func regenerate() throws -> any AppSigningKey {
        lock.lock()
        defer { lock.unlock() }
        try keychain.delete(nil, what: Self.what)
        return key(try keychain.create(label: nil, what: Self.what))
    }

    public func lookup() -> ItemLookup<any AppSigningKey> {
        keychain.lookup(nil).map { key($0) }
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try keychain.delete(nil, what: Self.what)
    }

    private func key(_ k: SecKey) -> any AppSigningKey {
        SecureEnclaveSigningKey(SecureEnclaveRef(key: k, what: Self.what, protectedData: keychain.protectedData))
    }
}

/// A Secure Enclave signing key: ECDSA P-256 with SHA-256, DER signatures (`ecdsaSignatureMessageX962SHA256`).
struct SecureEnclaveSigningKey: AppSigningKey {
    let ref: SecureEnclaveRef

    init(_ ref: SecureEnclaveRef) { self.ref = ref }

    func spki() throws -> [UInt8] {
        do {
            return Array(try P256.Signing.PublicKey(x963Representation: try ref.publicPoint()).derRepresentation)
        } catch let e as KeysError {
            throw e
        } catch {
            throw KeysError.invalid(ref.what)
        }
    }

    func sign(_ message: [UInt8]) throws -> [UInt8] {
        try ref.run { error in
            SecKeyCreateSignature(ref.key, .ecdsaSignatureMessageX962SHA256, Data(message) as CFData, &error)
        }
    }
}

/// A Secure Enclave key-agreement key: ECDH (`ecdhKeyExchangeStandard`), the x-coordinate of the shared point.
struct SecureEnclaveAgreementKey: KeyAgreementKey {
    let ref: SecureEnclaveRef

    init(_ ref: SecureEnclaveRef) { self.ref = ref }

    func publicKey() throws -> [UInt8] { try ref.publicPoint() }

    func agree(_ peer: [UInt8]) throws -> [UInt8] {
        // Full point validation before the Secure Enclave sees the point (IOS-PLAN §6.3).
        let point = Data(try SoftwareECDH.publicKey(peer).x963Representation)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let peerKey = SecKeyCreateWithData(point as CFData, attributes as CFDictionary, nil) else {
            throw KeysError.invalid("peer point")
        }
        let shared = try ref.run { error in
            SecKeyCopyKeyExchangeResult(ref.key, .ecdhKeyExchangeStandard, peerKey, [:] as CFDictionary, &error)
        }
        guard shared.count == 32 else { throw KeysError.invalid(ref.what) }
        return shared
    }
}

/// The seed-wrapping key in the Secure Enclave (IOS-PLAN §6.1; ``SeedWrapper``): a P-256 key-agreement key,
/// `AfterFirstUnlockThisDeviceOnly` like the wrapped seeds, so that the relay key works in the background. Mirrors
/// vettid-android `SeedWrapKey`.
public final class SecureEnclaveSeedWrapKeySource: SeedWrapKeySource, @unchecked Sendable {
    public static let tag = "com.vettid.seedwrap.v1"
    static let what = "seed wrapping key"

    private let keychain: SecureEnclaveKeychain
    private let lock = NSLock()

    public init(tag: String = SecureEnclaveSeedWrapKeySource.tag, protectedData: any ProtectedData) {
        keychain = SecureEnclaveKeychain(tag: tag, accessible: .afterFirstUnlockThisDeviceOnly, protectedData: protectedData)
    }

    /// The key, made only on a genuine "no such item" (a key refused for now is never replaced: the seeds wrapped under
    /// it would be lost).
    public func getOrCreate() throws -> any KeyAgreementKey {
        lock.lock()
        defer { lock.unlock() }
        switch keychain.lookup(nil) {
        case .found(let k): return key(k)
        case .unavailable: throw KeysError.unavailable(Self.what)
        case .missing:
            try keychain.delete(nil, what: Self.what)
            return key(try keychain.create(label: nil, what: Self.what))
        }
    }

    /// The key if there is one (the "keys usable" check), classified by IOS-PLAN §6.3.
    public func lookup() -> ItemLookup<any KeyAgreementKey> {
        keychain.lookup(nil).map { key($0) }
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try keychain.delete(nil, what: Self.what)
    }

    private func key(_ k: SecKey) -> any KeyAgreementKey {
        SecureEnclaveAgreementKey(SecureEnclaveRef(key: k, what: Self.what, protectedData: keychain.protectedData))
    }
}

/// The phone keys `P` in the Secure Enclave (VAULT-MESSAGING §11.14.1 "On an iPhone"; IOS-PLAN ID9, §6.3): P-256
/// key-agreement keys, **`WhenUnlockedThisDeviceOnly`**, so that their ECDH works only while the iPhone is unlocked (a
/// refusal while it is locked is ``KeysError/unavailable(_:)``, never a loss), labelled ``PhoneKeyLabel`` with their
/// `key_vault` and key id. Release code makes `P` only here (IOS-PLAN §6.3, "No software phone key in Release or Staging
/// builds"). Mirrors vettid-android `PhoneKey`.
public final class SecureEnclavePhoneSecretSource: PhoneSecretSource, @unchecked Sendable {
    public static let tag = "com.vettid.phone.v1"
    static let what = "phone key"

    private let keychain: SecureEnclaveKeychain
    public let sourceID: String

    /// [tag] names this source's keys and is its ``sourceID``; tests pass their own.
    public init(tag: String = SecureEnclavePhoneSecretSource.tag, protectedData: any ProtectedData) {
        keychain = SecureEnclaveKeychain(tag: tag, accessible: .whenUnlockedThisDeviceOnly, protectedData: protectedData)
        sourceID = tag
    }

    public func create(keyVault: String) throws -> (keyID: String, key: any KeyAgreementKey) {
        let id = PhoneKeyLabel.newKeyID()
        let made = try keychain.create(label: PhoneKeyLabel.make(keyVault: keyVault, keyID: id), what: Self.what)
        return (id, key(made))
    }

    public func lookup(keyVault: String, keyID: String) -> ItemLookup<any KeyAgreementKey> {
        keychain.lookup(PhoneKeyLabel.make(keyVault: keyVault, keyID: keyID)).map { key($0) }
    }

    public func delete(keyVault: String, keyID: String) throws {
        try keychain.delete(PhoneKeyLabel.make(keyVault: keyVault, keyID: keyID), what: Self.what)
    }

    public func keyNames() throws -> [PhoneKeyName] {
        try keychain.labels(what: Self.what).compactMap(PhoneKeyLabel.parse)
    }

    public func deleteAll() throws {
        try keychain.delete(nil, what: Self.what)
    }

    private func key(_ k: SecKey) -> any KeyAgreementKey {
        SecureEnclaveAgreementKey(SecureEnclaveRef(key: k, what: Self.what, protectedData: keychain.protectedData))
    }
}

extension PhoneKeyLabel {
    /// The name in a label made by ``make(keyVault:keyID:)``; nil for any other label.
    public static func parse(_ label: String) -> PhoneKeyName? {
        let parts = label.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix, !parts[2].isEmpty else { return nil }
        return PhoneKeyName(keyVault: parts[1], keyID: parts[2])
    }
}
