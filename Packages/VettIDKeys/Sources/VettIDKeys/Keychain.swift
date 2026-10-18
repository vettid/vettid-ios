import CryptoKit
import Foundation
import Security
import VettIDCrypto

/// One generic-password item of the data-protection keychain (IOS-PLAN §6.1): `ThisDeviceOnly`, never synchronizable,
/// so never in iCloud Keychain or a backup. Nothing read or written here is logged.
public struct KeychainItem: Sendable {
    /// Every VettID item's service: the first-run cleanup and a wipe find them by it, and by everything else.
    public static let service = "com.vettid.keys"

    public let account: String
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` or `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
    public let accessible: Accessible

    public enum Accessible: Sendable {
        case afterFirstUnlockThisDeviceOnly
        case whenUnlockedThisDeviceOnly

        var value: CFString {
            switch self {
            case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    public init(account: String, accessible: Accessible) {
        self.account = account
        self.accessible = accessible
    }

    private var base: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: false,
        ]
    }

    /// What the lookup itself answered (`errSecItemNotFound` is "no such item"; every other error is "failed").
    public func read() -> RawLookup<[UInt8]> {
        var query = base
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess:
            guard let data = out as? Data else { return .failed }
            return .found(Array(data))
        case errSecItemNotFound:
            return .noSuchItem
        default:
            return .failed
        }
    }

    /// The item, classified by IOS-PLAN §6.3.
    public func lookup(_ protectedData: any ProtectedData) -> ItemLookup<[UInt8]> {
        ProtectedLookup.run(protectedData) { read() }
    }

    /// Adds the item, or replaces its value.
    public func write(_ value: [UInt8]) throws {
        if try add(value) { return }
        let update: [CFString: Any] = [kSecValueData: Data(value), kSecAttrAccessible: accessible.value]
        guard SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecSuccess else {
            throw KeysError.unavailable("keychain item \(account)")
        }
    }

    /// Adds the item only if there is none: false when one already exists (its value is left alone).
    public func add(_ value: [UInt8]) throws -> Bool {
        var add = base
        add[kSecValueData] = Data(value)
        add[kSecAttrAccessible] = accessible.value
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess: return true
        case errSecDuplicateItem: return false
        default: throw KeysError.unavailable("keychain item \(account)")
        }
    }

    public func delete() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeysError.unavailable("keychain item \(account)")
        }
    }
}

/// Removes every keychain item and key the app can reach, of every class, synchronizable or not (IOS-PLAN §6.1: the
/// first-run cleanup "deletes every VettID keychain item and Secure Enclave key it finds"; a wipe). Keychain items
/// survive removing the app, so this also removes what an earlier installation left.
public struct KeychainEraser: KeyEraser {
    public init() {}

    static var classes: [CFString] {
        [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey, kSecClassCertificate, kSecClassIdentity]
    }

    /// Every class is tried, whatever an earlier one answered; the first failure is thrown at the end.
    public func deleteAll() throws {
        var failure: KeysError?
        for itemClass in Self.classes {
            let query: [CFString: Any] = [
                kSecClass: itemClass,
                kSecUseDataProtectionKeychain: true,
                kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound && failure == nil {
                failure = KeysError.unavailable("keychain (\(status))")
            }
        }
        if let failure { throw failure }
    }

    /// Whether any item or key the app can reach is left (a wipe's check that nothing is). Throws when a lookup fails
    /// for another reason than "no such item".
    public func itemsLeft() throws -> Bool {
        for itemClass in Self.classes {
            let query: [CFString: Any] = [
                kSecClass: itemClass,
                kSecUseDataProtectionKeychain: true,
                kSecAttrSynchronizable: kSecAttrSynchronizableAny,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnAttributes: true,
            ]
            var out: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &out) {
            case errSecSuccess: return true
            case errSecItemNotFound: continue
            case let status: throw KeysError.unavailable("keychain (\(status))")
            }
        }
        return false
    }
}

/// The key of the encrypted files (``EncryptedFileStore``): 32 random bytes in the keychain,
/// `AfterFirstUnlockThisDeviceOnly` (the collector reads files while the phone is locked), made only when the lookup
/// genuinely found none. Mirrors vettid-android `KeystoreFileStore.ALIAS`.
public final class KeychainFileKeyHolder: FileKeyHolder, @unchecked Sendable {
    public static let account = "vettid.local_files.v1"

    private let item: KeychainItem
    private let protectedData: any ProtectedData
    private let lock = NSLock()

    public init(account: String = KeychainFileKeyHolder.account, protectedData: any ProtectedData) {
        item = KeychainItem(account: account, accessible: .afterFirstUnlockThisDeviceOnly)
        self.protectedData = protectedData
    }

    public func key() throws -> SymmetricKey {
        try lock.withLock {
            switch item.lookup(protectedData) {
            case .found(var bytes):
                defer { Bytes.wipe(&bytes) }
                guard bytes.count == 32 else { throw KeysError.corrupt("file key") }
                return SymmetricKey(data: bytes)
            case .missing:
                // Add-only: a key another caller added meanwhile is read back and used, never overwritten.
                var fresh = Randomness.bytes(32)
                defer { Bytes.wipe(&fresh) }
                if try item.add(fresh) { return SymmetricKey(data: fresh) }
                guard case .found(var bytes) = item.lookup(protectedData), bytes.count == 32 else {
                    throw KeysError.unavailable("file key")
                }
                defer { Bytes.wipe(&bytes) }
                return SymmetricKey(data: bytes)
            case .unavailable:
                throw KeysError.unavailable("file key")
            }
        }
    }

    public func deleteAll() throws { try lock.withLock { try item.delete() } }
}

/// Wrapped seeds in the keychain (ciphertext only; the wrapping key comes from a hardware key agreement),
/// `AfterFirstUnlockThisDeviceOnly` so that the relay key works in the background. Mirrors vettid-android
/// `SharedPreferencesWrappedKeyStore`.
public final class KeychainWrappedKeyStore: WrappedKeyStore, @unchecked Sendable {
    public static let accountPrefix = "vettid.seed"

    private let protectedData: any ProtectedData
    private let prefix: String

    /// [prefix] names the items (`<prefix>.<slot>.v1`); tests pass their own so they never touch the app's.
    public init(protectedData: any ProtectedData, accountPrefix prefix: String = KeychainWrappedKeyStore.accountPrefix) {
        self.protectedData = protectedData
        self.prefix = prefix
    }

    private func item(_ slot: KeySlot) -> KeychainItem {
        KeychainItem(account: "\(prefix).\(slot.rawValue).v1", accessible: .afterFirstUnlockThisDeviceOnly)
    }

    /// The blob; nil only when it is genuinely missing (IOS-PLAN §6.3).
    public func get(_ slot: KeySlot) throws -> [UInt8]? {
        switch item(slot).lookup(protectedData) {
        case .found(let b): b
        case .missing: nil
        case .unavailable: throw KeysError.unavailable("\(slot.rawValue) key")
        }
    }

    public func put(_ slot: KeySlot, _ blob: [UInt8]) throws { try item(slot).write(blob) }

    public func remove(_ slot: KeySlot) throws { try item(slot).delete() }
}
