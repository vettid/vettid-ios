#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDOnboarding
@testable import VettIDOnboardingUI
import VettIDUI

/// The unlock screen's ways forward, texts and secret input. Mirrors vettid-android `UnlockStuckTest` (the state's rules
/// and what the screen shows for them; vettid-android clicks through Compose's test rule, here the rules the screen uses
/// as they are and the rendered screen are checked) and the unlock's part of `CodeKeyboardsTest`.
@MainActor
@Suite struct UnlockScreensTests {
    let release = ReleaseView(number: 3, pcr0: String(repeating: "aa", count: 48), status: "active", endsAt: nil, notes: "")

    var ok: UnlockState {
        var s = UnlockState(loading: false)
        s.preflight = PreflightInfo(routed: release, lastNumber: 3, softwareUpdated: false, rollback: false, offer: nil)
        return s
    }

    var keysGone: UnlockState {
        var s = ok
        s.keysGone = true
        return s
    }

    var recoverOnly: [String: UnlockState] {
        var ended = UnlockState(loading: false)
        ended.preflightError = .releaseEnded
        var releaseRollback = UnlockState(loading: false)
        releaseRollback.preflight = PreflightInfo(routed: release, lastNumber: 4, softwareUpdated: false, rollback: true, offer: nil)
        var stateRollback = ok
        stateRollback.stateRollback = true
        return ["release ended": ended, "release rollback": releaseRollback, "state rollback": stateRollback]
    }

    var ordinary: [String: UnlockState] {
        func with(_ edit: (inout UnlockState) -> Void) -> UnlockState {
            var s = ok
            edit(&s)
            return s
        }
        var unknown = UnlockState(loading: false)
        unknown.preflightError = .releaseUnknown
        return [
            "ready": ok,
            "network": with { $0.message = .failed(.network, code: nil) },
            "bad pin": with { $0.message = .badPin },
            "transfer incomplete": with { $0.message = .failed(.transferIncomplete, code: "transfer_incomplete") },
            "release unknown": unknown,
            "recovery pending": with { $0.recoveryPending = true },
            "previous pin": with { $0.pinStep = .previous },
            "new pin": with { $0.pinStep = .new },
        ]
    }

    @Test func theWayForwardOfEachState() {
        for (name, s) in recoverOnly {
            #expect(s.recoverOnly, "\(name)")
            #expect(!s.eraseOffered, "\(name): no erase")
        }
        #expect(keysGone.eraseOffered && !keysGone.recoverOnly)
        for (name, s) in ordinary {
            #expect(!s.recoverOnly && !s.eraseOffered, "\(name)")
        }
    }

    /// A rollback wins over keys gone and an unrecognised phone: no erase, no confirmation.
    @Test func aRollbackWinsOverKeysGoneAndAnUnrecognisedPhone() {
        var both = recoverOnly["release rollback"] ?? ok
        both.keysGone = true
        both.notRecognised = true
        #expect(!both.eraseOffered && both.recoverOnly)
        // Every state renders.
        both.eraseConfirm = true
        for s in Array(recoverOnly.values) + Array(ordinary.values) + [keysGone, both] {
            #expect(height(UnlockScreen(state: s, actions: NoUnlockActions())) > 0)
        }
    }

    /// The support mail carries nothing of the member's.
    @Test func theSupportMailCarriesNothingOfTheMembers() {
        #expect(SupportMail.url.absoluteString == "mailto:support@vettid.org?subject=VettID%3A%20help%20with%20my%20vault")
    }

    /// IOS-PLAN §6.5: the PIN is never typed on a keyboard: the unlock screen has no text field for it. With the owner
    /// check due, the one field is the credential password's, with no AutoFill, no save prompt and no keyboard learning.
    @Test func thePinIsOnTheKeypadAndThePasswordFieldIsASecretOne() throws {
        let plain = host(UnlockScreen(state: ok, actions: NoUnlockActions()))
        #expect(textFields(in: plain).isEmpty, "no keyboard for the PIN")
        plain.isHidden = true

        var due = ok
        due.checkDue = true
        let window = host(UnlockScreen(state: due, actions: NoUnlockActions()))
        let fields = textFields(in: window)
        #expect(fields.count == 1)
        let field = try #require(fields.first)
        #expect(field.isSecureTextEntry)
        #expect(field.textContentType?.rawValue == "")
        #expect(field.autocorrectionType == .no && field.spellCheckingType == .no && field.inlinePredictionType == .no)
        #expect(field.smartQuotesType == .no && field.smartDashesType == .no && field.smartInsertDeleteType == .no)
        window.isHidden = true
    }

    /// The release R cancel of a recovery asks for the password in the same kind of field.
    @Test func theCancelPasswordIsASecretField() throws {
        var s = ok
        s.recoveryPending = true
        s.phoneSecret = true
        let window = host(UnlockScreen(state: s, actions: NoUnlockActions()))
        let field = try #require(textFields(in: window).first)
        #expect(field.isSecureTextEntry && field.textContentType?.rawValue == "")
        window.isHidden = true
    }

    /// Release L (VAULT-MESSAGING §3.6.8): the vault locked itself; the unlock and the check on one screen; the texts as
    /// ANDROID-PLAN §4 "Locking the vault" part 2 words them; a day is "1 day"; staging adds its note.
    @Test func anIdleLockIsSaidAndItsTextsAreAndroids() {
        #expect(OnboardingStrings.unlockIdleLockedTitle == "Your vault locked itself")
        #expect(OnboardingStrings.unlockIdleLocked(604_800)
            == "You hadn't checked in for 7 days, so your vault locked. Unlock it with your PIN and your credential password "
            + "to carry on. New messages wait for up to 14 days.")
        #expect(OnboardingStrings.unlockIdleLocked(86_400).hasPrefix("You hadn't checked in for 1 day, so"))
        #expect(OnboardingStrings.unlockIdleLocked(25_200).hasPrefix("You hadn't checked in for 7 hours, so"))
        #expect(OnboardingStrings.unlockIdleLocked(nil)
            == "You hadn't checked in, so your vault locked. Unlock it with your PIN and your credential password to carry on. "
            + "New messages wait for up to 14 days.")
        #expect(OnboardingStrings.ownerCheckIdleLockAt("Oct 13, 2026 at 11:00 AM")
            == "Your vault locks itself on Oct 13, 2026 at 11:00 AM if you don't check in.")
        for (after, scale) in [(Int64?.some(604_800), UInt64(1)), (25_200, 24), (nil, 1)] {
            var s = ok
            s.checkDue = true
            s.idleLocked = IdleLocked(afterSeconds: after)
            s.timeScale = scale
            #expect(height(UnlockScreen(state: s, actions: NoUnlockActions())) > 0)
        }
    }

    /// (VAULT-MESSAGING §3.6.5 "Ask only for what is used"; IOS-PLAN §6.6) The approved texts of the PIN and password screen and of
    /// the password-only retry, with Android's keys.
    @Test func theCheckInTextsAreTheApprovedOnes() {
        #expect(OnboardingStrings.unlockOwnerCheckTitle == "Unlock and check in")
        #expect(OnboardingStrings.unlockOwnerCheckBody
            == "Your daily check is due, so your vault needs your PIN and your credential password.")
        #expect(OnboardingStrings.unlockCheckIn == "Check in")
        #expect(OnboardingStrings.unlockCheckPasswordWrong(7)
            == "Your vault is unlocked, but the credential password was wrong, so your daily check didn't pass. "
            + "7 tries left before your vault locks again.")
        #expect(OnboardingStrings.unlockCheckPasswordWrong(1)
            == "Your vault is unlocked, but the credential password was wrong, so your daily check didn't pass. "
            + "1 try left before your vault locks again.")
        #expect(OnboardingStrings.unlockOwnerCheckLockedBody
            == "Your vault locked itself after ten wrong daily checks in a row. Unlock it with your PIN and your credential password.")
        #expect(OnboardingStrings.unlockCheckOpenWaiting == "Your vault is unlocked. Enter your credential password to check in.")
    }

    @Test func theTextsAreAndroids() {
        #expect(OnboardingStrings.unlockTitle == "Unlock your vault")
        #expect(OnboardingStrings.unlockBodyAccount("m***@example.com") == "Enter the vault PIN for m***@example.com.")
        #expect(OnboardingStrings.unlockWait(formatWait(272)) == "Too many wrong PINs. Try again in 4:32.")
        #expect(OnboardingStrings.unlockUpdatedBody(4, "aaaa bbbb", 3) == "Your vault now runs release 4 (fingerprint aaaa bbbb); "
            + "this phone last used release 3. Another of your devices approved this update. Continue only if you expected it.")
        #expect(OnboardingStrings.unlockRollbackBody(2, 3)
            == "Your vault is served by release 2, older than release 3 that this phone last used. VettID will not send your PIN to it.")
        #expect(OnboardingStrings.unlockLockUnconfirmedTitle == "Your vault may still be open")
        #expect(OnboardingStrings.unlockStuckBody.contains(#""I lost my phone: recover my vault""#))
        #expect(OnboardingStrings.unlockSignerRefusedHelpBody("24 hours").contains("\n\nIf that does not help"))
        #expect(OnboardingStrings.unlockSignerRefusedHelpBody("24 hours").contains("A recovery takes 24 hours and needs"))
        #expect(OnboardingStrings.erasePhoneBody("24 hours").contains("the credential backup must be on"))
        #expect(OnboardingStrings.rootLongUnreachable("7 days") == "VettID has not reached your vault for 7 days or more.")
        #expect(OnboardingStrings.rootStartOverBody.hasSuffix("could afterwards get back into it only with a recovery."))
        #expect(!OnboardingStrings.unlockRecoverOnlyBody.contains("  "))
        // ANDROID-PLAN 0.1.45 "A lost answer to a PIN or password change".
        #expect(OnboardingStrings.unlockPreviousPinTitle == "Enter your previous PIN")
        #expect(OnboardingStrings.unlockPreviousPinBody
            == "Your last PIN change got no answer. If it went through, VettID will ask for your new PIN next.")
        #expect(OnboardingStrings.unlockNewPinTitle == "Your PIN change went through.")
        #expect(OnboardingStrings.unlockNewPinBody == "Enter your new PIN.")
    }

    /// The root's stuck screens: the way out of each failure, confirmed; recover-or-erase where the vault is long out of
    /// reach or no longer accepts this phone. Mirrors vettid-android `UnreachableScreen`'s `WayOut`.
    @Test func theWayOutOfEachStuckScreen() {
        #expect(WayOut.of(.noVault) == .startOver)
        #expect(WayOut.of(.localState) == .erase)
        #expect(WayOut.of(.unauthorized) == .eraseOrRecover)
        #expect(WayOut.of(.network) == nil)
        #expect(WayOut.of(.network, longUnreachable: true) == .eraseOrRecover)
        #expect(WayOut.of(.clock, longUnreachable: true) == nil)
        #expect(WayOut.of(nil, longUnreachable: true) == nil)
        #expect(UnreachableScreen.title(.clock) == "Check this phone's date and time")
        #expect(UnreachableScreen.title(.network) == "VettID cannot connect")
        for kind in [FailureKind.network, .clock, .noVault, .localState, .unauthorized] {
            let screen = UnreachableScreen(kind: kind, busy: false, onRetry: {}, onStartOver: { _ in }, onRecover: {})
            #expect(height(screen) > 0)
        }
    }

    /// IOS-PLAN §4.4 (1): "This phone can't use your vault", with "Try again" and "Lock vault".
    @Test func theCredentialRequiredScreen() {
        #expect(height(CredentialRequiredScreen(onRetry: {}, onLock: {})) > 0)
        #expect(FailureKind.credentialRequiredTitle == "This phone can't use your vault")
        #expect(OnboardingStrings.rootRetry == "Try again")
        #expect(OnboardingStrings.ownerCheckLock == "Lock vault")
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
#endif
