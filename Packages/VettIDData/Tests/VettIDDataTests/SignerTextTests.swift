import Foundation
import Testing
@testable import VettIDData

/// The texts of the signer confirmation in a transfer (VAULT-MESSAGING 0.27.0 §11.7.1; ANDROID-PLAN 0.1.36 §7: the wording
/// is the requirement). Mirrors vettid-android's `settings_transfer_signer_*`.
@Suite struct SignerTextTests {
    @Test func theNewAndTheCurrentSignerAreNamedInTheApprovedWords() {
        #expect(SignerText.changeBody(new: .googlePlay, current: .vettid)
            == "The new phone's VettID was installed from Google Play (signed by Google); this one is from F-Droid or direct "
            + "(signed by VettID). Continue only if you installed it yourself.")
        #expect(SignerText.changeBody(new: .vettid, current: .googlePlay)
            == "The new phone's VettID was installed from F-Droid or direct (signed by VettID); this one is from Google Play "
            + "(signed by Google). Continue only if you installed it yourself.")
        #expect(SignerText.changeBody(new: .development, current: .vettid)
            == "The new phone's VettID is a development build; this one is from F-Droid or direct (signed by VettID). "
            + "Continue only if you installed it yourself.")
        #expect(SignerText.changeBody(new: .vettid, current: .development)
            == "The new phone's VettID was installed from F-Droid or direct (signed by VettID); this one is a development "
            + "build. Continue only if you installed it yourself.")
    }

    @Test func aClassThisAppDoesNotKnowHasItsOwnHalf() {
        #expect(SignerText.changeBody(new: nil, current: .vettid)
            == "The new phone's VettID has a different signer; this one is from F-Droid or direct (signed by VettID). "
            + "Continue only if you installed it yourself.")
        #expect(SignerClass.of("google_play") == .googlePlay && SignerClass.of("vettid") == .vettid)
        #expect(SignerClass.of("hardware") == nil && SignerClass.of(nil) == nil)
    }

    /// (Owner decision, 2026-10-23.) An iPhone has no signer to name: the body names the new phone's only.
    @Test func anIPhoneNamesOnlyTheNewPhone() {
        #expect(SignerText.changeBody(new: .googlePlay, current: nil)
            == "The new phone's VettID was installed from Google Play (signed by Google). That is not the version your vault "
            + "used on Android before. Continue only if you installed it yourself.")
    }
}
