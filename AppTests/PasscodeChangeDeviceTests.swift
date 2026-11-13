import CryptoKit
import Foundation
import VettIDKeys
import XCTest

/// A passcode change, and turning the passcode off and on again, keep the phone key (IOS-PLAN §8 I1.4: the phone key is
/// `WhenUnlockedThisDeviceOnly`, never bound to the passcode). Half automated, in runs of the `VettIDDevice` scheme with
/// a person changing the passcode between them (Settings → Face ID & Passcode), `VETTID_TEST_PASSCODE` set to:
///
/// - `keep`: a test phone key is made, and what it agrees with a fresh software key is kept (its SHA-256, with the
///   key's id and the software public key) in the app's Application Support;
/// - `verify`: the same key is found by its label and agrees to the same value; nothing is deleted, so that one key can
///   be verified after a passcode change, with the passcode off, and after it is on again;
/// - `check`: as `verify`, then the key and the kept file are deleted.
///
/// Skipped without `VETTID_TEST_PASSCODE`. The key has a test tag of its own: the app's keys are never touched. Run
/// `keep` on an app that has been launched before: the first-run cleanup of a fresh install erases every key, this
/// test's too.
final class PasscodeChangeDeviceTests: XCTestCase {
    static let phoneTag = "vettid.test.passcode.phone"
    static let keyVault = "vault-passcode-test"

    let on = ProtectedDataFlag(available: true)

    private var step: String? { ProcessInfo.processInfo.environment["VETTID_TEST_PASSCODE"] }

    /// What `keep` leaves for the later runs: the key's id, the software public key and the SHA-256 of the agreed value.
    private struct Kept: Codable {
        let keyID: String
        let ePub: [UInt8]
        let zHash: [UInt8]
    }

    private var keptURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("passcode-device-test.json")
    }

    private var source: SecureEnclavePhoneSecretSource { SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: on) }

    override func setUpWithError() throws {
        try XCTSkipUnless(hasSecureEnclave, "no Secure Enclave on this device")
        try XCTSkipUnless(step != nil, "VETTID_TEST_PASSCODE not set")
    }

    func testThePhoneKeyOutlivesAPasscodeChange() throws {
        switch step {
        case "keep": try keep()
        case "verify": try verify()
        case "check":
            defer { erase() }
            try verify()
        default: XCTFail("VETTID_TEST_PASSCODE is keep, verify or check")
        }
    }

    private func keep() throws {
        erase()
        do {
            let made = try source.create(keyVault: Self.keyVault)
            let e = P256.KeyAgreement.PrivateKey()
            let z = try SoftwareECDH.agree(e, try made.key.publicKey())
            let kept = Kept(keyID: made.keyID, ePub: Array(e.publicKey.x963Representation), zHash: Array(SHA256.hash(data: z)))
            try FileManager.default.createDirectory(at: keptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(kept).write(to: keptURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        } catch {
            erase()
            throw error
        }
        print("PasscodeChangeDeviceTests: kept; change the passcode (or turn it off), then run verify or check")
    }

    private func verify() throws {
        let kept = try JSONDecoder().decode(Kept.self, from: Data(contentsOf: keptURL))
        let found = try source.lookup(keyVault: Self.keyVault, keyID: kept.keyID).get("phone key after the passcode change")
        XCTAssertEqual(Array(SHA256.hash(data: try found.agree(kept.ePub))), kept.zHash, "the same key agrees to the same value")
        XCTAssertEqual(try source.keyNames(), [PhoneKeyName(keyVault: Self.keyVault, keyID: kept.keyID)])
    }

    private func erase() {
        try? source.deleteAll()
        try? FileManager.default.removeItem(at: keptURL)
    }
}
