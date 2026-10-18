import Foundation
import LocalAuthentication
import Security
import Testing
@testable import VettIDKeys
import VettIDKeysTesting

/// The app-lock key (IOS-PLAN §6.1, ID17): what a failed use of the Secure Enclave key means for the lock, and the
/// software stand-in the simulator's tests use. The Secure Enclave key itself is accepted on the iPhone (I1.4).
@Suite struct AppLockKeysTests {
    private func error(_ domain: String, _ code: Int) -> CFError {
        CFErrorCreate(nil, domain as CFString, code, nil)
    }

    @Test func aCancelledPromptIsNotALostKey() {
        #expect(SecureEnclaveAppLockKeys.classify(error(NSOSStatusErrorDomain, Int(errSecUserCanceled))) == .cancelled)
        #expect(SecureEnclaveAppLockKeys.classify(error(LAErrorDomain, LAError.userCancel.rawValue)) == .cancelled)
        #expect(SecureEnclaveAppLockKeys.classify(error(LAErrorDomain, LAError.systemCancel.rawValue)) == .cancelled)
    }

    @Test func aKeyThatNoLongerOpensIsInvalidated() {
        #expect(SecureEnclaveAppLockKeys.classify(error(NSOSStatusErrorDomain, Int(errSecItemNotFound))) == .invalidated)
        #expect(SecureEnclaveAppLockKeys.classify(error(LAErrorDomain, LAError.passcodeNotSet.rawValue)) == .invalidated)
        // Face ID turned off for the app, or a key reference iOS no longer accepts: never a lock the member cannot pass.
        #expect(SecureEnclaveAppLockKeys.classify(error(LAErrorDomain, LAError.biometryNotAvailable.rawValue)) == .invalidated)
        #expect(SecureEnclaveAppLockKeys.classify(error(NSOSStatusErrorDomain, Int(errSecInvalidKeyRef))) == .invalidated)
    }

    /// A Face ID or Touch ID key made for another set of faces or fingers no longer opens, whatever iOS answers then.
    @Test func aChangedSetOfFacesInvalidatesTheKey() {
        let then = Data([1, 2, 3])
        let record = SecureEnclaveAppLockKeys.record(.biometrics, then)
        #expect(SecureEnclaveAppLockKeys.stillValid(record, now: then))
        #expect(!SecureEnclaveAppLockKeys.stillValid(record, now: Data([9])))
        // iOS says nothing now: the key's own answer decides; the passcode method has no set.
        #expect(SecureEnclaveAppLockKeys.stillValid(record, now: nil))
        #expect(SecureEnclaveAppLockKeys.stillValid(SecureEnclaveAppLockKeys.record(.passcode, nil), now: Data([9])))
        #expect(SecureEnclaveAppLockKeys.stillValid(nil, now: Data([9])))
    }

    @Test func aLockoutIsTriedAgainAfterThePasscode() {
        #expect(SecureEnclaveAppLockKeys.classify(error(LAErrorDomain, LAError.biometryLockout.rawValue)) == .lockedOut)
        #expect(SecureEnclaveAppLockKeys.classify(error(NSOSStatusErrorDomain, Int(errSecAuthFailed))) == .failed)
        #expect(SecureEnclaveAppLockKeys.classify(nil) == .failed)
    }

    @Test func theSoftwareKeySealsAndOpensAndCanBeInvalidated() async throws {
        let k = SoftwareAppLockKeys()
        #expect(try !k.exists())
        try k.create(.passcode)
        let sealed = try k.seal([1, 2, 3])
        #expect(try await k.open(sealed, reason: "r") == [1, 2, 3])
        k.nextPrompts(.cancel)
        await #expect(throws: AppLockKeyError.cancelled) { _ = try await k.open(sealed, reason: "r") }
        k.nextPrompts(.lockout, .unavailable)
        await #expect(throws: AppLockKeyError.lockedOut) { _ = try await k.open(sealed, reason: "r") }
        await #expect(throws: AppLockKeyError.invalidated) { _ = try await k.open(sealed, reason: "r") }
        k.lookupFails = true
        #expect(throws: KeysError.self) { _ = try k.exists() }
        k.lookupFails = false
        k.invalidate()
        await #expect(throws: AppLockKeyError.invalidated) { _ = try await k.open(sealed, reason: "r") }
        #expect(k.created == [.passcode] && k.opens == 5)
    }
}
