import CryptoKit
import Foundation
import UIKit
import VettIDKeys
import XCTest

/// The Secure Enclave keys while the iPhone is locked (IOS-PLAN §8 I1.4): the app key and the seed key sign and agree
/// with the phone locked after its first unlock; the phone key's ECDH and lookup are refused for now (never "missing"
/// or "invalid") while it is locked, and work again once it is unlocked. Half automated: it needs someone to lock and
/// unlock the phone, so it runs only with `VETTID_TEST_LOCK_WAIT=<seconds>` (each wait's limit) and is skipped
/// otherwise, and skipped when the phone is not locked in time.
final class LockedPhoneDeviceTests: XCTestCase {
    static let appTag = "vettid.test.locked.appkey"
    static let seedTag = "vettid.test.locked.seedwrap"
    static let phoneTag = "vettid.test.locked.phone"

    let on = ProtectedDataFlag(available: true)

    private var wait: Double {
        get throws {
            let value = ProcessInfo.processInfo.environment["VETTID_TEST_LOCK_WAIT"].flatMap(Double.init)
            return try XCTUnwrap(value, "VETTID_TEST_LOCK_WAIT not set")
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(hasSecureEnclave, "no Secure Enclave on this device")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETTID_TEST_LOCK_WAIT"] != nil, "VETTID_TEST_LOCK_WAIT not set")
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
    }

    @MainActor
    func testTheKeysWhileThePhoneIsLocked() async throws {
        let monitor = ProtectedDataMonitor()
        monitor.start()
        let app = SecureEnclaveAppKeyStore(tag: Self.appTag, protectedData: monitor)
        let seed = SecureEnclaveSeedWrapKeySource(tag: Self.seedTag, protectedData: monitor)
        let phone = SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: monitor)
        _ = try app.getOrCreate()
        _ = try seed.getOrCreate()
        let p = try phone.create(keyVault: "v")
        let e = P256.KeyAgreement.PrivateKey()
        let z = try SoftwareECDH.agree(e, try p.key.publicKey())
        let ePub = Array(e.publicKey.x963Representation)

        print("LockedPhoneDeviceTests: lock the iPhone now (side button)")
        guard try await until(try wait, { !UIApplication.shared.isProtectedDataAvailable }) else {
            throw XCTSkip("the iPhone was not locked in time")
        }
        // Locked after its first unlock: the AfterFirstUnlock keys work.
        XCTAssertEqual(KeysUsableCheck.appKey(app), .usable, "the app key signs while the phone is locked")
        XCTAssertEqual(KeysUsableCheck.agreement(seed.lookup()), .usable, "the seed key agrees while the phone is locked")
        // The WhenUnlocked phone key is refused for now: never lost.
        let lookup = phone.lookup(keyVault: "v", keyID: p.keyID)
        XCTAssertTrue(isUnavailable(lookup), "a locked lookup is not missing")
        XCTAssertEqual(KeysUsableCheck.agreement(lookup), .unavailable)
        XCTAssertThrowsError(try p.key.agree(ePub)) { XCTAssertEqual(KeysUsability.of($0), .unavailable, "\($0)") }
        XCTAssertThrowsError(try phone.keyNames()) { XCTAssertEqual(KeysUsability.of($0), .unavailable, "\($0)") }
        // A stale flag that still says "available": the keychain's and the Secure Enclave's own answers keep it a refusal
        // for now, never missing or invalid.
        let stale = SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: ProtectedDataFlag(available: true))
        let staleLookup = stale.lookup(keyVault: "v", keyID: p.keyID)
        XCTAssertFalse(isMissing(staleLookup), "a locked lookup is not missing, whatever the flag says")
        if case .found(let k) = staleLookup {
            XCTAssertThrowsError(try k.agree(ePub)) { XCTAssertEqual(KeysUsability.of($0), .unavailable, "\($0)") }
        }
        XCTAssertNotEqual(KeysUsableCheck.agreement(staleLookup), .lost)

        print("LockedPhoneDeviceTests: unlock the iPhone now")
        guard try await until(try wait, { UIApplication.shared.isProtectedDataAvailable }) else {
            return XCTFail("the iPhone was not unlocked in time")
        }
        let again = try phone.lookup(keyVault: "v", keyID: p.keyID).get("phone key")
        XCTAssertEqual(try again.agree(ePub), z, "the phone key works once the phone is unlocked")
        XCTAssertEqual(try p.key.agree(ePub), z)
    }

    /// Polls [condition] every half second until it holds or [seconds] pass.
    @MainActor
    private func until(_ seconds: Double, _ condition: @MainActor () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return condition()
    }
}
