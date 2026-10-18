import CryptoKit
import Foundation
import Security
import Testing
import VettIDKeys

/// VettIDKeys's keychain path (IOS-PLAN §6.1), here because it needs the app's keychain entitlement: a package's test
/// bundle has none (`errSecMissingEntitlement`), and `swift test` on macOS has no data-protection keychain. These tests
/// may run on a phone that holds a real vault, so they touch only their own `vettid.test.*` items; the full
/// ``KeychainEraser`` runs only when `VETTID_TEST_ERASE_KEYCHAIN=1` is set (off by default).
@Suite(.serialized) struct KeychainTests {
    static let accounts = ["item", "file_key", "other_key", "added", "attrs", "a", "b", "c"].map { "vettid.test.\($0)" }
        + KeySlot.allCases.map { "vettid.test.seed.\($0.rawValue).v1" }

    let on = ProtectedDataFlag(available: true)

    init() throws {
        for account in Self.accounts {
            try KeychainItem(account: account, accessible: .afterFirstUnlockThisDeviceOnly).delete()
        }
    }

    @Test func anItemIsWrittenReadReplacedAndDeleted() throws {
        let item = KeychainItem(account: "vettid.test.item", accessible: .afterFirstUnlockThisDeviceOnly)
        #expect(item.lookup(on) == .missing)
        // Not missing while protected data is unavailable.
        #expect(item.lookup(ProtectedDataFlag()) == .unavailable)
        try item.write([1, 2, 3])
        #expect(item.lookup(on) == .found([1, 2, 3]))
        try item.write([4])
        #expect(item.lookup(on) == .found([4]))
        try item.delete()
        try item.delete()
        #expect(item.lookup(on) == .missing)
    }

    /// The file key is made once, on a genuine "no such item", and the store reads its files with it.
    @Test func theFileKeyIsMadeOnceAndKept() throws {
        let holder = KeychainFileKeyHolder(account: "vettid.test.file_key", protectedData: on)
        let k1 = try holder.key()
        let k2 = KeychainFileKeyHolder(account: "vettid.test.file_key", protectedData: on)
        #expect(try k2.key().withUnsafeBytes { Array($0) } == k1.withUnsafeBytes { Array($0) })
        // With protected data unavailable an absent key is not made.
        let other = KeychainFileKeyHolder(account: "vettid.test.other_key", protectedData: ProtectedDataFlag())
        #expect(throws: KeysError.unavailable("file key")) { try other.key() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = EncryptedFileStore(url: dir.appendingPathComponent("f"), purpose: "p", keys: holder, protectedData: on)
        try store.save([7])
        #expect(try store.load() == [7])
        try holder.deleteAll()
        // A new key cannot read the old file: damaged, not missing.
        #expect(throws: KeysError.corrupt("f")) { try store.load() }
    }

    @Test func wrappedSeedsLiveInTheKeychain() throws {
        let store = KeychainWrappedKeyStore(protectedData: on, accountPrefix: "vettid.test.seed")
        let wrapKey = P256.KeyAgreement.PrivateKey()
        let keys = DeviceKeys(wrapper: SeedWrapper { TestAgreementKey(agreement: wrapKey) }, store: store)
        #expect(try store.get(.identity) == nil)
        try keys.generate(.identity)
        #expect(try store.get(.identity) != nil)
        #expect(try keys.ed25519(.identity).publicKey.count == 32)
        // An absent blob while protected data is unavailable is not "missing".
        let locked = KeychainWrappedKeyStore(protectedData: ProtectedDataFlag(), accountPrefix: "vettid.test.seed")
        #expect(throws: KeysError.unavailable("kem key")) { try locked.get(.kem) }
        try keys.clear()
        #expect(try store.get(.identity) == nil)
    }

    /// Adding is add-only: an existing item (the file key another caller made) is left alone and reported.
    @Test func addNeverOverwrites() throws {
        let item = KeychainItem(account: "vettid.test.added", accessible: .afterFirstUnlockThisDeviceOnly)
        #expect(try item.add([1]))
        #expect(try !item.add([2]))
        #expect(item.lookup(on) == .found([1]))
    }

    /// The stored attributes: ThisDeviceOnly, the class asked for, never synchronizable.
    @Test func itemsAreThisDeviceOnlyAndNotSynchronizable() throws {
        for (accessible, expected) in [
            (KeychainItem.Accessible.afterFirstUnlockThisDeviceOnly, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
            (.whenUnlockedThisDeviceOnly, kSecAttrAccessibleWhenUnlockedThisDeviceOnly),
        ] {
            let item = KeychainItem(account: "vettid.test.attrs", accessible: accessible)
            try item.delete()
            try item.write([1])
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword, kSecAttrService: KeychainItem.service, kSecAttrAccount: "vettid.test.attrs",
                kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: kSecAttrSynchronizableAny,
                kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            #expect(SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess)
            let attrs = try #require(out as? [String: Any])
            #expect(attrs[kSecAttrAccessible as String] as? String == expected as String)
            #expect((attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
            try item.delete()
        }
    }

    /// The eraser removes every item, whatever its account. It erases everything the app can reach, so it runs only on
    /// request (never on a phone that holds a real vault).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VETTID_TEST_ERASE_KEYCHAIN"] == "1"))
    func theEraserRemovesEveryItem() throws {
        let items = ["a", "b", "c"].map { KeychainItem(account: "vettid.test.\($0)", accessible: .whenUnlockedThisDeviceOnly) }
        for item in items { try item.write([1]) }
        #expect(try KeychainEraser().itemsLeft())
        try KeychainEraser().deleteAll()
        #expect(items.allSatisfy { $0.lookup(on) == .missing })
        #expect(try !KeychainEraser().itemsLeft(), "a wipe's check finds nothing")
        try KeychainEraser().deleteAll()
    }

    /// A wipe's check that nothing is left sees an item of the app.
    @Test func itemsLeftSeesAnItem() throws {
        let item = KeychainItem(account: "vettid.test.left", accessible: .whenUnlockedThisDeviceOnly)
        try item.write([1])
        defer { try? item.delete() }
        #expect(try KeychainEraser().itemsLeft())
    }
}

/// A software key-agreement key (the app tests do not link VettIDKeysTesting).
private struct TestAgreementKey: KeyAgreementKey {
    let agreement: P256.KeyAgreement.PrivateKey

    func publicKey() throws -> [UInt8] { Array(agreement.publicKey.x963Representation) }

    func agree(_ peer: [UInt8]) throws -> [UInt8] { try SoftwareECDH.agree(agreement, peer) }
}
