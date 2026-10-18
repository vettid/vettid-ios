import CryptoKit
import Foundation
import Security
import VettIDCrypto
import VettIDKeys
import XCTest

/// The Secure Enclave keys on a real iPhone (IOS-PLAN §8 I1.4, §6.1, §6.3): skipped where there is no Secure Enclave
/// (the simulator, CI). They may run on a phone that holds a real vault, so they use only their own `vettid.test.*`
/// tags and items, and the app's keys are never touched; the full ``KeychainEraser`` runs only with
/// `VETTID_TEST_ERASE_KEYCHAIN=1`. Nothing here needs a person at the phone (``LockedPhoneDeviceTests`` does).
final class SecureEnclaveDeviceTests: XCTestCase {
    static let appTag = "vettid.test.se.appkey"
    static let seedTag = "vettid.test.se.seedwrap"
    static let phoneTag = "vettid.test.se.phone"
    static let seedPrefix = "vettid.test.se.seed"

    let on = ProtectedDataFlag(available: true)

    override func setUpWithError() throws {
        try XCTSkipUnless(hasSecureEnclave, "no Secure Enclave on this device")
        try erase()
    }

    override func tearDownWithError() throws {
        guard hasSecureEnclave else { return }
        try erase()
    }

    private func erase() throws {
        try SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: on).deleteAll()
        try SecureEnclaveSeedWrapKeySource(tag: Self.seedTag, protectedData: on).deleteAll()
        try SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: on).deleteAll()
        try KeychainWrappedKeyStore(protectedData: on, accountPrefix: Self.seedPrefix).deleteAll()
    }

    /// The app key signs, its signature verifies under its SPKI, it is found again, and the "keys usable" check passes.
    func testTheAppKeySigns() throws {
        let store = SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: on)
        XCTAssertTrue(isMissing(store.lookup()))
        let key = try store.getOrCreate()
        let spki = try key.spki()
        let message = Array("vettid/ios/device-test".utf8)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: try key.sign(message))
        XCTAssertTrue(try P256.Signing.PublicKey(derRepresentation: spki).isValidSignature(sig, for: message))
        XCTAssertEqual(try store.getOrCreate().spki(), spki, "the same key is found again")
        XCTAssertEqual(KeysUsableCheck.appKey(store), .usable)
        XCTAssertEqual(try key.akid().count, 32)
        try checkAttributes(tag: Self.appTag, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        // A new key replaces it.
        XCTAssertNotEqual(try store.regenerate().spki(), spki)
        XCTAssertEqual(try keyCount(Self.appTag), 1)
    }

    /// The seed-wrapping key agrees (both ways with a software key), and the device seeds are wrapped under it in the
    /// keychain and read back; a blob wrapped for one slot does not open as another.
    func testTheSeedKeysAgreeAndWrap() throws {
        let source = SecureEnclaveSeedWrapKeySource(tag: Self.seedTag, protectedData: on)
        let k = try source.getOrCreate()
        let e = P256.KeyAgreement.PrivateKey()
        XCTAssertEqual(try k.agree(Array(e.publicKey.x963Representation)), try SoftwareECDH.agree(e, try k.publicKey()))
        XCTAssertEqual(KeysUsableCheck.agreement(source.lookup()), .usable)
        try checkAttributes(tag: Self.seedTag, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

        let store = KeychainWrappedKeyStore(protectedData: on, accountPrefix: Self.seedPrefix)
        let wrapper = SeedWrapper(source: source)
        let keys = DeviceKeys(wrapper: wrapper, store: store)
        for slot in KeySlot.allCases { try keys.generate(slot) }
        XCTAssertEqual(try keys.ed25519(.identity).publicKey, try keys.ed25519(.identity).publicKey)
        XCTAssertEqual(try keys.kem().publicKey, try keys.kem().publicKey)
        let blob = try XCTUnwrap(try store.get(.identity))
        XCTAssertThrowsError(try wrapper.unwrap(.relay, blob))
        // Another process's source over the same tag reads the same seeds.
        let again = SeedWrapper(source: SecureEnclaveSeedWrapKeySource(tag: Self.seedTag, protectedData: on))
        XCTAssertEqual(try again.unwrap(.identity, blob).count, 32)
    }

    /// The phone key of ID9: made for a `key_vault`, found again by its label, ECDH equal to the software side's, listed,
    /// its secret computed and checked as IOS-PLAN §6.3 says, and deleted.
    func testThePhoneKeyIsCreatedUsedAndDeleted() throws {
        let source = SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: on)
        let made = try source.create(keyVault: "vault-device-test")
        let transfer = try source.create(keyVault: "")
        let names = Set(try source.keyNames())
        XCTAssertEqual(names, [
            PhoneKeyName(keyVault: "vault-device-test", keyID: made.keyID), PhoneKeyName(keyVault: "", keyID: transfer.keyID),
        ])
        let found = try source.lookup(keyVault: "vault-device-test", keyID: made.keyID).get("phone key")
        let pub = try found.publicKey()
        XCTAssertEqual(pub, try made.key.publicKey())
        XCTAssertEqual(pub.count, 65)
        XCTAssertNotEqual(try transfer.key.publicKey(), pub)

        // §6.3 at a new epoch: E_e in software, z_e both ways.
        let e = P256.KeyAgreement.PrivateKey()
        let ePub = Array(e.publicKey.x963Representation)
        let z = try SoftwareECDH.agree(e, pub)
        XCTAssertEqual(try found.agree(ePub), z)
        XCTAssertEqual(KeysUsableCheck.agreement(source.lookup(keyVault: "vault-device-test", keyID: made.keyID)), .usable)
        // A point not on the curve never reaches the Secure Enclave.
        var bad = ePub
        bad[64] ^= 1
        XCTAssertThrowsError(try found.agree(bad))
        try checkAttributes(tag: Self.phoneTag, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, count: 2)

        try source.delete(keyVault: "vault-device-test", keyID: made.keyID)
        XCTAssertTrue(isMissing(source.lookup(keyVault: "vault-device-test", keyID: made.keyID)))
        XCTAssertEqual(try source.keyNames(), [PhoneKeyName(keyVault: "", keyID: transfer.keyID)])
        // Another key_vault's label never finds it.
        XCTAssertTrue(isMissing(source.lookup(keyVault: "other", keyID: transfer.keyID)))
    }

    /// A deleted key is detected as unusable (IOS-PLAN §6.1 "keys usable"): the app key, the seed key and the phone key.
    func testADeletedKeyIsUnusable() throws {
        let app = SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: on)
        _ = try app.getOrCreate()
        let seed = SecureEnclaveSeedWrapKeySource(tag: Self.seedTag, protectedData: on)
        _ = try seed.getOrCreate()
        let phone = SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: on)
        let p = try phone.create(keyVault: "v")
        XCTAssertEqual(KeysUsability.combine([
            KeysUsableCheck.appKey(app), KeysUsableCheck.agreement(seed.lookup()),
            KeysUsableCheck.agreement(phone.lookup(keyVault: "v", keyID: p.keyID)),
        ]), .usable)
        try app.deleteAll()
        try seed.deleteAll()
        try phone.delete(keyVault: "v", keyID: p.keyID)
        XCTAssertEqual(KeysUsableCheck.appKey(app), .lost)
        XCTAssertEqual(KeysUsableCheck.agreement(seed.lookup()), .lost)
        XCTAssertEqual(KeysUsableCheck.agreement(phone.lookup(keyVault: "v", keyID: p.keyID)), .lost)
        // Seeds wrapped under the deleted key do not open under the new one: lost, never refused for now.
        let store = KeychainWrappedKeyStore(protectedData: on, accountPrefix: Self.seedPrefix)
        let keys = DeviceKeys(wrapper: SeedWrapper(source: seed), store: store)
        try keys.generate(.relay)
        try seed.deleteAll()
        XCTAssertThrowsError(try keys.ed25519(.relay)) { XCTAssertEqual(KeysUsability.of($0), .lost) }
    }

    /// IOS-PLAN §6.3: a lookup during which protected data goes away is not "missing", and neither is one while it is
    /// unavailable; a key that exists is found either way.
    func testALookupWhileProtectedDataGoesAwayIsNotMissing() throws {
        let fading = FadingProtectedData(availableReads: 1)
        XCTAssertTrue(isUnavailable(SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: fading)
            .lookup(keyVault: "v", keyID: "absent")))
        let off = ProtectedDataFlag()
        XCTAssertTrue(isUnavailable(SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: off).lookup()))
        XCTAssertThrowsError(try SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: off).getOrCreate()) {
            XCTAssertEqual($0 as? KeysError, .unavailable("app key"))
        }
        XCTAssertEqual(try keyCount(Self.appTag), 0, "nothing is made while the lookup is refused")
        _ = try SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: on).getOrCreate()
        guard case .found = SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: off).lookup() else {
            return XCTFail("a key that exists is found")
        }
    }

    /// The first-run cleanup (IOS-PLAN §6.1) removes the Secure Enclave keys and keychain items it is given (here only
    /// this test's), and nothing before the first unlock (protected data unavailable).
    func testTheFirstRunCleanupRemovesTheKeys() throws {
        let app = SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: on)
        let seed = SecureEnclaveSeedWrapKeySource(tag: Self.seedTag, protectedData: on)
        let phone = SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: on)
        let wrapped = KeychainWrappedKeyStore(protectedData: on, accountPrefix: Self.seedPrefix)
        _ = try app.getOrCreate()
        let p = try phone.create(keyVault: "v")
        try DeviceKeys(wrapper: SeedWrapper(source: seed), store: wrapped).generate(.kem)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vettid-se-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let erasers: [any KeyEraser] = [wrapped, app, seed, phone]

        let beforeUnlock = FirstRunCleanup(directory: dir, protectedData: ProtectedDataFlag(), erasers: erasers, dataFiles: [])
        XCTAssertEqual(try beforeUnlock.run(), .deferred)
        XCTAssertEqual(try keyCount(Self.appTag) + keyCount(Self.seedTag) + keyCount(Self.phoneTag), 3, "nothing deleted")

        let cleanup = FirstRunCleanup(directory: dir, protectedData: on, erasers: erasers, dataFiles: [])
        XCTAssertEqual(try cleanup.run(), .cleaned)
        XCTAssertEqual(try keyCount(Self.appTag) + keyCount(Self.seedTag) + keyCount(Self.phoneTag), 0)
        XCTAssertNil(try wrapped.get(.kem))
        XCTAssertTrue(isMissing(phone.lookup(keyVault: "v", keyID: p.keyID)), "the old phone key is not used")
        XCTAssertEqual(try cleanup.run(), .alreadyDone)
    }

    /// The app's full cleanup (``KeychainEraser``) removes Secure Enclave keys too. It erases every key and item of the
    /// app, so it runs only on request.
    func testTheKeychainEraserRemovesSecureEnclaveKeys() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETTID_TEST_ERASE_KEYCHAIN"] == "1", "VETTID_TEST_ERASE_KEYCHAIN=1 not set")
        _ = try SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: on).getOrCreate()
        _ = try SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: on).create(keyVault: "v")
        try KeychainEraser().deleteAll()
        XCTAssertEqual(try keyCount(Self.appTag) + keyCount(Self.phoneTag), 0)
        XCTAssertFalse(try KeychainEraser().itemsLeft())
    }

    // MARK: - Helpers

    /// The stored key items of [tag]: in the Secure Enclave, of the class asked for, never synchronizable.
    private func checkAttributes(tag: String, accessible: CFString, count: Int = 1) throws {
        let items = try attributes(tag)
        XCTAssertEqual(items.count, count)
        for a in items {
            XCTAssertEqual(a[kSecAttrTokenID as String] as? String, kSecAttrTokenIDSecureEnclave as String)
            XCTAssertNotEqual((a[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue, true)
            // The protection class is the access control's (`cku`: AfterFirstUnlockThisDeviceOnly, `aku`:
            // WhenUnlockedThisDeviceOnly); the item's own `pdmn` reads `dk` for a Secure Enclave key made with an
            // access control.
            let access = String(describing: try XCTUnwrap(a[kSecAttrAccessControl as String], "access control"))
            XCTAssertTrue(access.hasPrefix("<SecAccessControlRef: \(Self.shortClass(accessible));"), access)
            // `.privateKeyUsage` only: no biometry, passcode or user presence constraint.
            for bound in ["bio", "pbioc", "cpo", "dpo", "pkofn", "prp"] { XCTAssertFalse(access.contains("\(bound)("), access) }
        }
    }

    private static func shortClass(_ c: CFString) -> String {
        c == kSecAttrAccessibleWhenUnlockedThisDeviceOnly ? "aku" : "cku"
    }

    private func attributes(_ tag: String) throws -> [[String: Any]] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey, kSecAttrApplicationTag: Data(tag.utf8), kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        XCTAssertEqual(status, errSecSuccess)
        return out as? [[String: Any]] ?? []
    }

    private func keyCount(_ tag: String) throws -> Int { try attributes(tag).count }
}

/// A real Secure Enclave: the simulator reports one (iOS 27), but its keys ignore the access control's protection class.
var hasSecureEnclave: Bool {
    #if targetEnvironment(simulator)
    false
    #else
    SecureEnclave.isAvailable
    #endif
}

func isMissing<T>(_ l: ItemLookup<T>) -> Bool {
    if case .missing = l { return true }
    return false
}

func isUnavailable<T>(_ l: ItemLookup<T>) -> Bool {
    if case .unavailable = l { return true }
    return false
}

/// Protected data that is available for the first [availableReads] reads and then goes away: a lookup during which the
/// iPhone locks.
final class FadingProtectedData: ProtectedData, @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int

    init(availableReads: Int) {
        left = availableReads
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        left -= 1
        return left >= 0
    }
}
