#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDOnboarding
@testable import VettIDOnboardingUI
import VettIDUI

/// The owner-check screen, the held screen's waiting card, the app lock's screen and the way out of a wipe that did not
/// finish: texts, secret input and every state rendered.
@MainActor
@Suite struct OwnerCheckScreensTests {
    let now = Date(timeIntervalSince1970: 1_791_384_000)

    var held: OwnerCheckScreenState {
        OwnerCheckScreenState(
            mode: .gated,
            view: OwnerCheckView(
                state: .held, deadline: now.addingTimeInterval(-60), failures: 2, waiting: WaitingCounts(messages: 3, calls: 1)
            )
        )
    }

    /// IOS-PLAN §6.5: the PIN on the keypad, never a keyboard; the one text field is the password's, with no AutoFill, no
    /// save prompt and no keyboard learning.
    @Test func thePinIsOnTheKeypadAndThePasswordFieldIsASecretOne() throws {
        let window = host(OwnerCheckScreen(state: held, actions: NoOwnerCheckActions(), now: now))
        let fields = textFields(in: window)
        #expect(fields.count == 1)
        let field = try #require(fields.first)
        #expect(field.isSecureTextEntry && field.textContentType?.rawValue == "")
        #expect(field.autocorrectionType == .no && field.spellCheckingType == .no && field.inlinePredictionType == .no)
        window.isHidden = true
    }

    /// Release L (§3.6.8): the held and daily-check screens say when the vault locks itself, while that time is ahead.
    @Test func theIdleLockTimeIsSaidOnTheGatedCheckOnly() {
        let at = now.addingTimeInterval(3_600)
        let v = OwnerCheckView(state: .held, deadline: now.addingTimeInterval(-60), idleLockAt: at)
        #expect(idleLockAtOf(.gated, v, now: now) == at)
        #expect(idleLockAtOf(.voluntary, v, now: now) == nil && idleLockAtOf(.holdOff, v, now: now) == nil)
        // Once that time has passed (a call in progress delays the lock): nothing; a vault before L: nothing.
        #expect(idleLockAtOf(.gated, v, now: at) == nil && idleLockAtOf(.gated, v, now: at.addingTimeInterval(1)) == nil)
        #expect(idleLockAtOf(.gated, OwnerCheckView(state: .held, deadline: nil), now: now) == nil)
        #expect(idleLockAtOf(.gated, nil, now: now) == nil)
        var s = held
        s.view = v
        #expect(height(OwnerCheckScreen(state: s, actions: NoOwnerCheckActions(), now: now)) > 0)
    }

    /// (IOS-PLAN §6.6; VAULT-MESSAGING §3.6.5) After an unlock whose check failed: the PIN is kept, no keypad, the password's
    /// secret field only; the wrong-password line, the backoff's, and the lock text render.
    @Test func theRetryAfterTheUnlockAsksOnlyForThePassword() throws {
        var s = held
        s.pinKept = true
        s.pin = "975310"
        s.unlockedWrong = 7
        let window = host(OwnerCheckScreen(state: s, actions: NoOwnerCheckActions(), now: now))
        let field = try #require(textFields(in: window).first)
        #expect(textFields(in: window).count == 1 && field.isSecureTextEntry)
        window.isHidden = true
        var wait = s
        wait.unlockedWrong = nil
        wait.unlockedOpen = true
        wait.waitSeconds = 272
        var locked = held
        locked.locked = true
        for state in [wait, locked, s] { #expect(height(OwnerCheckScreen(state: state, actions: NoOwnerCheckActions(), now: now)) > 0) }
    }

    /// (VAULT-MESSAGING 0.73.0 §3.6.5) Probably locked: no fields while the reads run or after them; a lock of unknown
    /// cause and an unanswered check above 0 render.
    @Test func probablyLockedHasNoFields() {
        for watch in [LockWatch.checking, .silent] {
            for mode in [OwnerCheckMode.gated, .voluntary] {
                var s = held
                s.mode = mode
                s.watch = watch
                let window = host(OwnerCheckScreen(state: s, actions: NoOwnerCheckActions(), now: now))
                #expect(textFields(in: window).isEmpty)
                window.isHidden = true
            }
        }
        var unknown = held
        unknown.locked = true
        unknown.lockCauseUnknown = true
        var maybe = held
        maybe.message = .maybeCounted(atLeast: 1)
        for s in [unknown, maybe] { #expect(height(OwnerCheckScreen(state: s, actions: NoOwnerCheckActions(), now: now)) > 0) }
    }

    /// The approved texts (owner, 2026-10-28; VAULT-MESSAGING 0.73.0, 0.73.2).
    @Test func theProbablyLockedTextsAreTheApprovedOnes() {
        #expect(OnboardingStrings.ownerCheckProbablyLockedChecking
            == "Your daily check didn't pass, and your vault has probably locked itself. Checking with your vault…")
        #expect(OnboardingStrings.ownerCheckProbablyLockedSilent
            == "Your vault isn't answering. It has probably locked itself after ten wrong daily checks in a row.")
        #expect(OnboardingStrings.ownerCheckCheckAgain == "Check again")
        #expect(OnboardingStrings.unlockCheckMaybeCounted(1)
            == "Your vault didn't answer, so that check may have counted. At least 1 try left before your vault locks.")
        #expect(OnboardingStrings.unlockCheckMaybeCounted(4)
            == "Your vault didn't answer, so that check may have counted. At least 4 tries left before your vault locks.")
        #expect(OnboardingStrings.unlockLockConfirmed == "Your vault is locked.")
    }

    @Test func everyStateRenders() {
        var states: [OwnerCheckScreenState] = [held, OwnerCheckScreenState(mode: .voluntary), OwnerCheckScreenState(mode: .holdOff)]
        for m in [OwnerCheckMessage.badPin(checksLeft: 2), .badPassword(checksLeft: 8), .backoff, .failed(.network, code: nil)] {
            var s = held
            s.message = m
            states.append(s)
        }
        var waiting = held
        waiting.waitSeconds = 30
        var presence = held
        presence.presenceUnrecorded = true
        var passed = presence
        passed.passedUnrecorded = true
        states += [waiting, presence, passed]
        for s in states { #expect(height(OwnerCheckScreen(state: s, actions: NoOwnerCheckActions(), now: now)) > 0) }
        #expect(height(AppLockScreen(passcodeOnly: false) {}) > 0)
        #expect(height(AppLockScreen(passcodeOnly: true) {}) > 0)
        #expect(height(AppLockScreen(passcodeOnly: false, lockedOut: true) {}) > 0)
        #expect(OnboardingStrings.appLockLockedOut == "Unlock your iPhone with its passcode, then try again.")
    }

    /// `vault.held`'s counts as the held screen shows them: unknown is never "nothing new"; the hold's note.
    @Test func theWaitingCardSaysWhatWaits() {
        #expect(WaitingCard.text(WaitingCardModel(counts: WaitingCounts(messages: 3, calls: 1), held: true))
            == "3 new messages\n1 missed call\n\n" + OnboardingStrings.ownerCheckHeldNote)
        #expect(WaitingCard.text(WaitingCardModel(counts: WaitingCounts(), held: false))
            == "Nothing new has arrived since your check was due.\n\n" + OnboardingStrings.ownerCheckDueNote)
        #expect(WaitingCard.text(WaitingCardModel(counts: nil, held: nil)) == OnboardingStrings.ownerCheckWaitingUnknown)
    }

    @Test func theTextsAreAndroids() {
        #expect(OnboardingStrings.ownerCheckBodyGated(OwnerCheckScreenState().intervalText) == "Your vault asks for your PIN and "
            + "your credential password together at least once every 24 hours. Until you check, the app shows nothing from your vault.")
        let hourly = OwnerCheckScreenState(view: OwnerCheckView(state: .ok, deadline: nil, intervalSeconds: 3_600))
        #expect(hourly.intervalText == "1 hour")
        #expect(OnboardingStrings.ownerCheckChecksLeft(1) == "1 wrong check left before your vault locks.")
        #expect(OnboardingStrings.ownerCheckChecksLeft(8) == "8 wrong checks left before your vault locks.")
        #expect(OnboardingStrings.ownerCheckWaitingRequests(1) == "1 connection request")
        #expect(OnboardingStrings.ownerCheckWaitingOther(2) == "2 other updates")
        #expect(OnboardingStrings.ownerCheckBackoffWait(formatWait(272)) == "Too many wrong entries. Try again in 4:32.")
        #expect(OnboardingStrings.ownerCheckHoldOffWarning.hasSuffix("This phone still asks for the check before you can use it."))
        #expect(OnboardingStrings.appLockTitle == "VettID is locked" && AppLockTexts.reason == "Unlock VettID")
        #expect(OnboardingStrings.rootClearData == "Erase VettID's data on this phone")
    }

    /// A wipe that did not finish: "Erase VettID's data on this phone", confirmed; when it could not finish, how to go on.
    @Test func theWayOutOfAFailedWipe() {
        #expect(UnreachableScreen.label(.clearData) == "Erase VettID's data on this phone")
        #expect(UnreachableScreen.confirmLabel(.clearData) == "Erase")
        #expect(UnreachableScreen.confirmTitle(.clearData) == "Erase VettID's data?")
        #expect(UnreachableScreen.title(.eraseFailed) == OnboardingStrings.rootEraseFailedTitle)
        for failed in [false, true] {
            let screen = UnreachableScreen(
                kind: .eraseFailed, busy: false, clearFailed: failed, onRetry: {}, onStartOver: { _ in }, onRecover: {}
            )
            #expect(height(screen) > 0)
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
#endif
