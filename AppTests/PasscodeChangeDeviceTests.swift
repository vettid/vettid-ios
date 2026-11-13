import CryptoKit
import Foundation
import VettIDKeys
import XCTest

/// A passcode change, and turning the passcode off and on again, keep the phone key (IOS-PLAN §8 I1.4: the phone key is
/// `WhenUnlockedThisDeviceOnly`, never bound to the passcode). Half automated, in two runs with a person between them:
///
/// 1. `VETTID_TEST_PASSCODE=keep`: a test phone key is made, and its ECDH with a fresh software key is kept in the app's
///    caches (the test key's output, nothing of the app's own).
/// 2. The person changes the iPhone's passcode, or turns it off and on again (Settings → Face ID & Passcode).
/// 3. `VETTID_TEST_PASSCODE=check`: the same key is found by its label, agrees to the same value, and is deleted.
///
/// Skipped without `VETTID_TEST_PASSCODE`. The key has a test tag of its own: the app's keys are never touched.
final class PasscodeChangeDeviceTests: XCTestCase {
    static let phoneTag = "vettid.test.passcode.phone"
    static let keyVault = "vault-passcode-test"

    let on = ProtectedDataFlag(available: true)

    private var step: String? { ProcessInfo.processInfo.environment["VETTID_TEST_PASSCODE"] }

    /// What the first run keeps for the second: the key's id, the software public key and the agreed value.
    private struct Kept: Codable {
        let keyID: String
        let ePub: [UInt8]
        let z: [UInt8]
    }

    private var keptURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("passcode-test.json")
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(hasSecureEnclave, "no Secure Enclave on this device")
        try XCTSkipUnless(step != nil, "VETTID_TEST_PASSCODE not set")
    }

    func testThePhoneKeyOutlivesAPasscodeChange() throws {
        let source = SecureEnclavePhoneSecretSource(tag: Self.phoneTag, protectedData: on)
        switch step {
        case "keep":
            try source.deleteAll()
            let made = try source.create(keyVault: Self.keyVault)
            let e = P256.KeyAgreement.PrivateKey()
            let z = try SoftwareECDH.agree(e, try made.key.publicKey())
            let kept = Kept(keyID: made.keyID, ePub: Array(e.publicKey.x963Representation), z: Array(z))
            try JSONEncoder().encode(kept).write(to: keptURL, options: .completeFileProtectionUntilFirstUserAuthentication)
            print("PasscodeChangeDeviceTests: kept; now change the passcode, or turn it off and on, then run check")
        case "check":
            let kept = try JSONDecoder().decode(Kept.self, from: Data(contentsOf: keptURL))
            defer {
                try? source.deleteAll()
                try? FileManager.default.removeItem(at: keptURL)
            }
            let found = try source.lookup(keyVault: Self.keyVault, keyID: kept.keyID).get("phone key after the passcode change")
            XCTAssertEqual(Array(try found.agree(kept.ePub)), kept.z, "the same key agrees to the same value")
            XCTAssertEqual(try source.keyNames(), [PhoneKeyName(keyVault: Self.keyVault, keyID: kept.keyID)])
        default:
            XCTFail("VETTID_TEST_PASSCODE is keep or check")
        }
    }
}
