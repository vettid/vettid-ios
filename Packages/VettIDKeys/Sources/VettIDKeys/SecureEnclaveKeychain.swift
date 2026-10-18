import CryptoKit
import Foundation
import Security

/// Secure Enclave P-256 keys kept by the keychain (IOS-PLAN §6.1, §6.3): made with `kSecAttrTokenIDSecureEnclave` as
/// permanent `kSecClassKey` items (the keychain holds the key's blob, which only this iPhone's Secure Enclave can use),
/// found again by their application tag (and, for the phone keys, their label), `ThisDeviceOnly`, never synchronizable,
/// with `.privateKeyUsage` only: never bound to biometry or the passcode, so a passcode change, or turning the passcode
/// off, keeps them. The Security framework's keys rather than CryptoKit's `SecureEnclave` types (chosen; not in the
/// spec): the keychain's own answer for the item then classifies every lookup by IOS-PLAN §6.3 (``ProtectedLookup``),
/// with no separate blob store. Nothing here is logged; errors carry no key material.
struct SecureEnclaveKeychain: Sendable {
    /// The keys' application tag: the app's own (`com.vettid.….v1`) or a test's (`vettid.test.…`).
    let tag: String
    let accessible: KeychainItem.Accessible
    let protectedData: any ProtectedData

    private var base: [CFString: Any] {
        [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag: Data(tag.utf8),
            kSecUseDataProtectionKeychain: true,
        ]
    }

    private func query(_ label: String?) -> [CFString: Any] {
        var q = base
        if let label { q[kSecAttrLabel] = label }
        return q
    }

    /// A new key in the Secure Enclave under [label] (nil: the tag alone names it). Throws
    /// ``KeysError/noSecureHardware`` where there is no Secure Enclave (``SecureEnclaveFailure/creation(domain:code:what:)``),
    /// and ``KeysError/unavailable(_:)`` when the keychain refuses for now (the iPhone locked).
    func create(label: String?, what: String) throws -> SecKey {
        guard SecureEnclave.isAvailable else { throw KeysError.noSecureHardware }
        guard let access = SecAccessControlCreateWithFlags(nil, accessible.value, .privateKeyUsage, nil) else {
            throw KeysError.unavailable(what)
        }
        var key: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: Data(tag.utf8),
            kSecAttrAccessControl: access,
        ]
        if let label { key[kSecAttrLabel] = label }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain: true,
            kSecPrivateKeyAttrs: key,
        ]
        var error: Unmanaged<CFError>?
        guard let made = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let e = error?.takeRetainedValue()
            let domain = e.map { CFErrorGetDomain($0) as String }
            throw SecureEnclaveFailure.creation(domain: domain, code: e.map { CFErrorGetCode($0) } ?? 0, what: what)
        }
        return made
    }

    /// What the keychain itself answered for the key [label] (nil: the tag's key).
    func read(_ label: String?) -> RawLookup<SecKey> {
        var q = query(label)
        q[kSecReturnRef] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess:
            guard let ref = out, CFGetTypeID(ref) == SecKeyGetTypeID() else { return .failed }
            // The type was checked just above.
            return .found(ref as! SecKey) // swiftlint:disable:this force_cast
        case errSecItemNotFound:
            return .noSuchItem
        default:
            return .failed
        }
    }

    /// The key [label], classified by IOS-PLAN §6.3.
    func lookup(_ label: String?) -> ItemLookup<SecKey> {
        ProtectedLookup.run(protectedData) { read(label) }
    }

    /// Removes the key [label] (nil: every key of the tag).
    func delete(_ label: String?, what: String) throws {
        let status = SecItemDelete(query(label) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeysError.unavailable(what) }
    }

    /// The labels of every key of the tag. Throws ``KeysError/unavailable(_:)`` unless the keychain answered.
    func labels(what: String) throws -> [String] {
        var q = base
        q[kSecReturnAttributes] = true
        q[kSecMatchLimit] = kSecMatchLimitAll
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess:
            guard let items = out as? [[String: Any]] else { throw KeysError.unavailable(what) }
            return items.compactMap { $0[kSecAttrLabel as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeysError.unavailable(what)
        }
    }
}

/// A Secure Enclave key reference used by the key objects (SecKey is thread-safe).
struct SecureEnclaveRef: @unchecked Sendable {
    let key: SecKey
    let what: String
    let protectedData: any ProtectedData

    /// The public key, SEC1 uncompressed (65 bytes).
    func publicPoint() throws -> [UInt8] {
        guard let pub = SecKeyCopyPublicKey(key) else { throw KeysError.invalid(what) }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw failure(error?.takeRetainedValue(), before: true)
        }
        return Array(data)
    }

    /// Runs one operation of the Secure Enclave and classifies its failure (``SecureEnclaveFailure``).
    func run(_ operation: (inout Unmanaged<CFError>?) -> CFData?) throws -> [UInt8] {
        let before = protectedData.isAvailable
        var error: Unmanaged<CFError>?
        guard let out = operation(&error) else { throw failure(error?.takeRetainedValue(), before: before) }
        return Array(out as Data)
    }

    private func failure(_ error: CFError?, before: Bool) -> KeysError {
        SecureEnclaveFailure.classify(
            domain: error.map { CFErrorGetDomain($0) as String }, code: error.map { CFErrorGetCode($0) } ?? 0,
            protectedBefore: before, protectedAfter: protectedData.isAvailable, what: what
        )
    }
}

/// What a failed use of a Secure Enclave key means (IOS-PLAN §6.3, "Lost keys against a locked iPhone"): the key is
/// **invalid** only when iOS says so (the key or its item is gone or refused as invalid) while protected data was
/// available before and after; any other failure, or protected data that went away, is refused for now.
public enum SecureEnclaveFailure {
    /// CryptoTokenKit's error domain (`TKErrorDomain`): the Secure Enclave's own answers.
    static let tokenDomain = "CryptoTokenKit"
    /// `TKError.Code.objectNotFound` and `.corruptedData`: the key blob is not this Secure Enclave's or is damaged.
    static let tokenInvalid: Set<Int> = [-6, -3]
    static let statusInvalid: Set<Int> = [
        Int(errSecInvalidKeyRef), Int(errSecInvalidItemRef), Int(errSecItemNotFound),
    ]

    /// A refused creation: "no secure hardware" only when iOS says the Secure Enclave cannot do it (`errSecUnimplemented`,
    /// `TKError.Code.notImplemented`); anything else (the iPhone locked, a busy keychain) is refused for now, and the
    /// member tries again.
    public static func creation(domain: String?, code: Int, what: String) -> KeysError {
        switch domain {
        case NSOSStatusErrorDomain where code == Int(errSecUnimplemented): .noSecureHardware
        case tokenDomain where code == -1: .noSecureHardware
        default: .unavailable(what)
        }
    }

    public static func classify(
        domain: String?, code: Int, protectedBefore: Bool, protectedAfter: Bool, what: String
    ) -> KeysError {
        guard protectedBefore, protectedAfter, let domain else { return .unavailable(what) }
        switch domain {
        case NSOSStatusErrorDomain where statusInvalid.contains(code): return .invalid(what)
        case tokenDomain where tokenInvalid.contains(code): return .invalid(what)
        default: return .unavailable(what)
        }
    }
}
