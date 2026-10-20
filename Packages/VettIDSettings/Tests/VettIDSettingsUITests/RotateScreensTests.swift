#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

/// The rotation, the clone alarm and a new credential: their texts (vettid-android's, word for word) and every state
/// rendered. Mirrors vettid-android's credential screen tests for `RotateContent`, `AlarmContent` and
/// `NewCredentialContent`.
@MainActor
@Suite struct RotateScreensTests {
    @Test func theTextsAreAndroids() {
        #expect(CredentialStrings.rotate == "Rotate the credential key" && CredentialStrings.rotateSubmit == "Rotate now")
        #expect(CredentialStrings.alarmBody("Oct 4, 2026 at 12:00 PM", CredentialStrings.alarmPresenterOther)
            == "At Oct 4, 2026 at 12:00 PM, another device presented a copy of your Protean Credential. Your vault refused it and "
            + "froze credential use. Messaging, connections and your other items keep working.")
        #expect(CredentialStrings.alarmPresenterHolder == "this phone's session")
        #expect(CredentialStrings.newWarning == "A new credential replaces the current one. Every critical item in it is destroyed "
            + "for good, on every device; nobody, VettID included, can bring them back. Your other items, connections and messages stay.")
        #expect(CredentialStrings.newSubmit == "Replace credential" && CredentialStrings.newPin == "Vault PIN")
    }

    /// Who presented the copy and when, as the alert said.
    @Test func theAlarmSaysWhoAndWhen() {
        let a = CredentialAlarm(alarmID: "a1", state: CredentialAlarm.stateFrozen, at: "not a time", presenter: "holder")
        #expect(AlarmContent.presenter(a) == CredentialStrings.alarmPresenterHolder)
        #expect(AlarmContent.presenter(nil) == CredentialStrings.alarmPresenterUnknown)
        #expect(AlarmContent.at(a) == "not a time" && AlarmContent.at(nil) == "-")
    }

    @Test func everyStateRenders() {
        var refused = RotateState(error: .badPassword)
        refused.password = "x"
        var busy = RotateState()
        busy.busy = true
        for s in [RotateState(), refused, busy, RotateState(done: true)] {
            #expect(height(RotateContent(state: s)) > 0)
        }
        let alarm = CredentialAlarm(alarmID: "a1", state: CredentialAlarm.stateFrozen, at: "2026-10-04T12:00:00Z", presenter: "other")
        var notMine = AlarmState(alarm: alarm, step: .rotate)
        notMine.notMine = true
        notMine.error = .badPassword
        var resolved = notMine
        resolved.step = .resolved
        let steps: [AlarmState] = [
            AlarmState(alarm: alarm), AlarmState(alarm: alarm, step: .confirmMine), AlarmState(alarm: nil, step: .confirmNotMine),
            notMine, resolved,
        ]
        for s in steps {
            #expect(height(AlarmContent(state: s)) > 0)
        }
        var filled = NewCredentialState()
        filled.current = "pw"
        filled.password = "a much better passphrase here"
        filled.confirm = filled.password
        filled.rule = .ok
        filled.acknowledged = true
        var wrong = filled
        wrong.mismatch = true
        wrong.error = .badPin
        var confirming = filled
        confirming.pin = "402817"
        confirming.confirming = true
        var checks: [NewCredentialState] = []
        for status in [ChangeCheck.Status.checking, .unreachable, .notApplied, .ended] {
            var c = NewCredentialState()
            c.check = status
            checks.append(c)
        }
        for s in [NewCredentialState(), filled, wrong, confirming, NewCredentialState(done: true)] + checks {
            #expect(height(NewCredentialContent(state: s)) > 0)
        }
    }

    /// A lost answer to New credential (ANDROID-PLAN 0.1.51, VAULT-MESSAGING 0.48.0 §11.14.9): the form's texts and the
    /// shell's one-time notice, word for word.
    @Test func theResetDecisionTexts() {
        #expect(NewCredentialContent.text(.checking) == "Your vault hasn't answered yet, so VettID is checking whether your new "
            + "credential was made. Keep your new password at hand.")
        #expect(NewCredentialContent.text(.unreachable) == "VettID can't reach your vault right now, so it doesn't know yet whether "
            + "your new credential was made. It will check as soon as it can. Keep both your old and your new password at hand.")
        #expect(NewCredentialContent.text(.notApplied) == "Your new credential wasn't made. Your credential, its password and your "
            + "critical items are unchanged.")
        #expect(NewCredentialContent.text(.ended) == "VettID couldn't confirm whether your new credential was made, because "
            + "something else changed in your vault at the same time. Either your previous or your new password may be the current one.")
        #expect(ChangeCheckNotice.text(ChangeCheck(.reset, .applied), timeScale: 1) == "Your new credential was made. Use your new "
            + "password from now on. Your critical items were deleted with the old credential.")
        #expect(ChangeCheckNotice.text(ChangeCheck(.reset, .notApplied), timeScale: 1) == NewCredentialContent.text(.notApplied))
        #expect(ChangeCheckNotice.text(ChangeCheck(.reset, .ended), timeScale: 1) == NewCredentialContent.text(.ended))
        #expect(ChangeCheckNotice.text(ChangeCheck(.reset, .checking), timeScale: 1) == nil)
        #expect(!ChangeCheckNotice.offersLockAndUnlock(ChangeCheck(.reset, .ended)))
    }

    /// The Credential screen's new rows and the alarm card's "Review" render.
    @Test func theCredentialScreenRendersItsNewRows() {
        let status = CredentialStatus(
            exists: true, version: 3, keyFingerprint: "abc", updatedAt: nil, alarm: nil, backup: true, unlockTtlSeconds: 300,
            criticalItems: 2
        )
        let alarm = CredentialAlarm(alarmID: "a1", state: CredentialAlarm.stateRotationRequired, at: nil)
        #expect(height(CredentialContent(state: CredentialState(loading: false, status: status, alarm: alarm))) > 0)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
