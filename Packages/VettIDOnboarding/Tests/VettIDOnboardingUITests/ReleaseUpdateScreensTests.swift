#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDOnboarding
@testable import VettIDOnboardingUI
import VettIDUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The update screen, the update's own screens and What's new: the texts are vettid-android's, every step has its
/// screen, and the PIN is on the keypad. Mirrors the release update's cases of vettid-android `OnboardingScreensTest`.
@MainActor
@Suite struct ReleaseUpdateScreensTests {
    func rel(_ n: UInt64, _ status: String = "active") -> ReleaseView {
        ReleaseView(number: n, pcr0: String(repeating: "ab", count: 48), status: status, endsAt: nil, notes: "https://vettid.org/security/releases/\(n)/")
    }

    let entry = ReleaseLogEntry(
        release: 5, summary: "Faster unlocks.", changes: ["Unlock takes one round trip."], security: .urgent,
        securityText: "Fixes a flaw in the PIN check."
    )

    @Test func theTextsAreAndroids() {
        #expect(OnboardingStrings.releaseNotesTitle(5) == "What's new in release 5")
        #expect(OnboardingStrings.releaseNotesInformation
            == "Release notes are information. What keeps your vault safe is the signed release list and the fingerprint below.")
        #expect(OnboardingStrings.releaseUpdateBody(5) == "Approve release 5 for your vault with your vault PIN.")
        #expect(OnboardingStrings.releaseUpdateApprove == "Approve and update")
        #expect(OnboardingStrings.releaseUpdateDoneBody(5, "abab abab") == "Your vault now runs release 5 (fingerprint abab abab) and is open.")
        #expect(OnboardingStrings.releaseUpdateNewFailedBody(5, 4) == "Your vault was moved to release 5 but did not open there. "
            + "Try again, or return to release 4: that is possible until release 5 has opened your vault once.")
        #expect(OnboardingStrings.releaseUpdateReturnConfirmBody(4, 5)
            == "Your vault goes back to release 4 and opens there. You can approve release 5 again later.")
        #expect(OnboardingStrings.releaseUpdateFailedBodyLockPending(4).hasSuffix("VettID keeps trying to lock the vault."))
        #expect(OnboardingStrings.unlockOfferTitle(5) == "Update available: release 5")
    }

    /// The refusal codes of §11.10.4 step 4 and a step 6 write failure, each in its own words; another code is named.
    @Test func eachRefusalHasItsText() {
        let codes = ["target", "downgrade", "approval", "seal_key", "pending", "write"]
        #expect(Set(codes.map { refusalText($0, 5) }).count == codes.count)
        #expect(refusalText("approval", 5) == "Your vault could not verify this phone's approval.")
        #expect(refusalText("not_moved", 5) == "Your vault did not move (not_moved).")
        var p = UpdateProgress(step: .failed, from: rel(4), to: rel(5), failure: .vaultUnavailable)
        p.failureCode = ReleaseUpdateManager.codeReleaseStarting
        #expect(updateFailureText(p) == "The new release did not start. Try again later.")
        #expect(updateFailureText(UpdateProgress(step: .badPin, from: rel(4), to: rel(5), failure: .backoff))
            == "Too many wrong PINs. Wait, then try again.")
    }

    /// The update screen with an offer (What's new loading, unavailable, available), without one, and with the check due;
    /// no keyboard for the PIN.
    @Test func theUpdateScreenRendersWithoutAKeyboard() {
        let offer = ReleaseUpdateOffer(current: rel(4, "retired"), target: rel(5))
        let notes: [ReleaseNotes?] = [nil, .unavailable, .available(host: "vettid.org", entry: entry, earlier: [EarlierRelease(release: 4, summary: "Four")])]
        for n in notes {
            let window = host(ReleaseUpdateContent(state: ReleaseUpdateState(loading: false, offer: offer, notes: n), onApprove: { _ in true }, onBack: {}))
            #expect(textFields(in: window).isEmpty, "no keyboard for the PIN")
            window.isHidden = true
        }
        for s in [ReleaseUpdateState(loading: false), ReleaseUpdateState(loading: true), ReleaseUpdateState(loading: false, offer: offer, checkDue: true)] {
            #expect(height(ReleaseUpdateContent(state: s, onApprove: { _ in true }, onBack: {})) > 0)
        }
    }

    /// Every step of the update has its screen; those that ask for the PIN have no keyboard.
    @Test func everyStepHasItsScreen() {
        let steps: [UpdateStep] = [.locking, .approving, .reopening, .done, .refused, .badPin, .failed, .newReleaseFailed, .abandoning, .abandoned]
        for step in steps {
            var p = UpdateProgress(step: step, from: rel(4), to: rel(5), failure: step == .badPin ? .badPin : .network, canAbandon: true)
            p.refusal = "approval"
            p.starting = step == .approving
            let window = host(ReleaseUpdateFlowContent(state: ReleaseUpdateFlowState(progress: p)))
            #expect(textFields(in: window).isEmpty, "\(step)")
            #expect(height(ReleaseUpdateFlowContent(state: ReleaseUpdateFlowState(progress: p))) > 0, "\(step)")
            window.isHidden = true
        }
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme()).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private func textFields(in view: UIView) -> [UITextField] { views(in: view).compactMap { $0 as? UITextField } }
}

// swiftlint:enable line_length
#endif
