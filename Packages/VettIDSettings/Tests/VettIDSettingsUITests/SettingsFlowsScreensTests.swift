#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDSettings
@testable import VettIDSettingsUI
import VettIDUI

/// The name change, the PIN change, the Credential screen and the password change: their texts (vettid-android's, word for
/// word), the name's status lines, and every state rendered. Mirrors vettid-android `ChangeNameScreenTest` and
/// `ReleaseRSettingsTest`'s PIN screen.
@MainActor
@Suite struct SettingsFlowsScreensTests {
    let now = Date(timeIntervalSince1970: 1_791_384_000)
    var account: AccountInfo { AccountInfo(emailHint: "a***@example.org", state: "member", firstName: "Ada", lastName: "Lovelace") }
    var pending: NameRequestView { NameRequestView(seq: 4, firstName: "Ada", lastName: "King", requestedAt: now, state: .pending) }

    @Test func theTextsAreAndroids() {
        #expect(NameStrings.checksLeft(6) == "6 more wrong tries lock your vault.")
        #expect(NameStrings.checksLeft(1) == "1 more wrong try locks your vault.")
        #expect(NameStrings.invalid == "Use letters, spaces and ' ’ . - only, starting with a letter.")
        #expect(PinStrings.pinDoneRecovery
            == "Your PIN was changed. Your vault's recovery now has 10 new attempts for the new PIN and your password.")
        // ANDROID-PLAN 0.1.45 "A lost answer to a PIN or password change".
        for texts in [
            ["PIN", PinStrings.pinChecking, PinStrings.pinNotChanged, PinStrings.pinUnreachable],
            ["password", CredentialStrings.passwordChecking, CredentialStrings.passwordNotChanged, CredentialStrings.passwordUnreachable],
        ] {
            let what = texts[0]
            #expect(texts[1] == "Your vault hasn't answered yet, so VettID is checking whether your \(what) was changed. "
                + "Keep your new \(what) at hand.")
            #expect(texts[2] == "Your \(what) was not changed. You can try again.")
            #expect(texts[3] == "VettID can't reach your vault right now, so it doesn't know yet whether your \(what) was "
                + "changed. It will check as soon as it can. Keep both your old and your new \(what) at hand.")
        }
        // The shell's notice of a decision reached while the screen was closed.
        #expect(ChangeCheckNotice.text(ChangeCheck(.pin, .checking), timeScale: 1) == nil)
        #expect(ChangeCheckNotice.text(ChangeCheck(.pin, .applied), timeScale: 1) == ChangeNoticeTexts.pinApplied)
        #expect(ChangeCheckNotice.text(ChangeCheck(.password, .applied), timeScale: 1) == ChangeNoticeTexts.passwordApplied)
        #expect(ChangeCheckNotice.text(ChangeCheck(.password, .notApplied), timeScale: 1) == ChangeNoticeTexts.passwordNotChanged)
        #expect(ChangeCheckNotice.text(ChangeCheck(.pin, .ended), timeScale: 1) == ChangeNoticeTexts.pinEnded)
        #expect(ChangeCheckNotice.text(ChangeCheck(.password, .ended), timeScale: 1) == ChangeNoticeTexts.passwordEnded)
        #expect(ChangeCheckNotice.offersLockAndUnlock(ChangeCheck(.pin, .ended)))
        #expect(!ChangeCheckNotice.offersLockAndUnlock(ChangeCheck(.password, .ended)))
        #expect(ChangeCheckNotice.lockAndUnlock == "Lock and unlock now")
        #expect(ChangeCheckNotice.text(ChangeCheck(.pin, .refused(.badPin, code: "bad_pin")), timeScale: 1) == FailureKind.badPin.message)
        // A refusal names a scaled wait at the vault's scale (STAGING-TIME-SCALE §5.2): the approved words in real time.
        let gone = ChangeCheck(.pin, .refused(.deviceSecret, code: "device_secret"))
        #expect(ChangeCheckNotice.text(gone, timeScale: 1)?.contains("It takes one to three days,") == true)
        #expect(ChangeCheckNotice.text(gone, timeScale: 24) == FailureKind.deviceSecret.message(timeScale: 24))
        #expect(ChangeCheckNotice.text(gone, timeScale: 24)?.contains("It takes 1 hour to 3 hours,") == true)
        #expect(ChangeCheckNotice.urgent(ChangeCheck(.pin, .ended)) && !ChangeCheckNotice.urgent(ChangeCheck(.pin, .applied)))
        #expect(PinStrings.vaultPin == "Change vault PIN" && PinStrings.securityCredential == "Credential")
        #expect(CredentialStrings.windowOpenUntil("3:00 PM") == "Open until 3:00 PM")
        #expect(CredentialStrings.ttlSeconds(45) == "45 seconds")
        #expect(CredentialContent.ttlLabel(900) == "15 minutes" && CredentialContent.ttlLabel(45) == "45 seconds")
    }

    /// vettid-android `nameStatusText`: a pending request, a refusal with its reason, or the next change's date.
    @Test func theNamesStatusLine() {
        var a = account
        #expect(NameStatus.text(a, now: now) == nil)
        a.nameRequest = pending
        #expect(NameStatus.text(a, now: now) == "Name change requested: \u{2068}Ada King\u{2069}")
        a.nameRequest = NameRequestView(seq: 4, firstName: "Ada", lastName: "King", requestedAt: now, state: .refused, reason: "account")
        #expect(NameStatus.text(a, now: now) == "Your account cannot change its name right now.")
        a.nameRequest?.reason = "too_soon"
        #expect(NameStatus.text(a, now: now) == "You can change your name once every 30 days.")
        let after = now.addingTimeInterval(86_400 * 12)
        a.nameAllowedAfter = after
        #expect(NameStatus.text(a, now: now)
            == "You can change your name once every 30 days. You can change it again on \(SettingsTimes.day(after)).")
        a.nameRequest = NameRequestView(seq: 4, firstName: "Ada", lastName: "King", requestedAt: now, state: .applied)
        #expect(NameStatus.text(a, now: now)?.hasPrefix("You can change your name once every 30 days.") == true)
    }

    @Test func theResultFollowsTheRequest() {
        var s = ChangeNameState(account: account)
        s.step = .sent
        s.request = pending
        #expect(ChangeNameSentStep.says(s).tag == "pending" && ChangeNameSentStep.says(s).title == "Name change requested")
        s.request?.state = .refused
        s.request?.reason = NameRequestView.reasonAccount
        #expect(ChangeNameSentStep.says(s).tag == "refused")
        #expect(ChangeNameSentStep.says(s).body == "Your account cannot change its name right now.")
        s.request?.state = .applied
        #expect(ChangeNameSentStep.says(s).body
            == "Your account name is now \u{2068}Ada King\u{2069}. Your connections get the new name from your vault.")
        #expect(ChangeNameNamesStep.error(.empty) == "Enter a name." && ChangeNameNamesStep.error(.ok) == nil)
    }

    /// vettid-android's `<b>` emphasis of the backup warning, as bold runs with the same words.
    @Test func theBackupWarningKeepsItsEmphasis() {
        let a = Emphasis.attributed(CredentialStrings.backupOffBody)
        #expect(String(a.characters).contains("your vault cannot be recovered. It can only"))
        #expect(!String(a.characters).contains("<b>"))
        let bold = a.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(a[$0.range].characters) }
        #expect(bold == ["cannot be recovered", "everything in it is lost"])
    }

    @Test func everyNameStateRenders() {
        var states: [ChangeNameState] = []
        var names = ChangeNameState(account: account)
        names.checked = true
        names.first = "Ada1"
        names.tooSoon = true
        states.append(names)
        var confirm = ChangeNameState(account: account)
        confirm.step = .confirm
        confirm.message = .badPassword(checksLeft: 2)
        states.append(confirm)
        confirm.message = .failed(.network)
        confirm.waitSeconds = 30
        states.append(confirm)
        for st in [NameRequestState.pending, .applied, .refused] {
            var sent = ChangeNameState(account: account)
            sent.step = .sent
            sent.request = NameRequestView(seq: 1, firstName: "Ada", lastName: "King", requestedAt: nil, state: st)
            states.append(sent)
        }
        for s in states {
            #expect(height(ChangeNameContent(state: s, now: now)) > 0)
        }
    }

    @Test func everyPinStateRenders() {
        var states = [ChangePinState(withPassword: true, fromAttempts: true)]
        var new = ChangePinState(withPassword: true)
        new.step = .new
        new.problem = .sequence
        states.append(new)
        var confirm = ChangePinState(withPassword: true)
        confirm.step = .confirm
        confirm.mismatch = true
        confirm.error = .badPin
        states.append(confirm)
        for check in [ChangeCheck.Status.checking, .unreachable, .notApplied] {
            var lost = ChangePinState(withPassword: true)
            lost.check = check
            states.append(lost)
        }
        var done = ChangePinState(withPassword: true)
        done.done = true
        states.append(done)
        for s in states {
            #expect(height(ChangePinContent(state: s)) > 0)
        }
    }

    /// IOS-PLAN §4.4 (3): `forbidden` to `pin.change` shows "Your vault moved to a new phone" and `vault_not_holder`.
    @Test func aPinChangeRefusedAsNotTheHolder() {
        #expect(ChangePinContent.failureTitle(.notHolder) == "Your vault moved to a new phone")
        #expect(ChangePinContent.failureTitle(.badPin) == ChangePinContent.failureTitle(.vaultCode("internal")))
        #expect(FailureKind.notHolder.message.hasPrefix("Another phone now holds your vault's credential"))
        var s = ChangePinState(withPassword: true)
        s.error = .notHolder
        #expect(height(ChangePinContent(state: s)) > 0)
    }

    @Test func everyCredentialStateRenders() {
        let status = CredentialStatus(
            exists: true, version: 3, keyFingerprint: "k1-012345678", updatedAt: "2026-10-04T12:00:00Z", alarm: nil, backup: false,
            unlockTtlSeconds: 900, criticalItems: nil
        )
        let alarm = CredentialAlarm(alarmID: "a", state: CredentialAlarm.stateRotationRequired, at: nil)
        let states = [
            CredentialState(),
            CredentialState(loading: false, error: .network),
            CredentialState(loading: false, status: CredentialStatus(
                exists: false, version: nil, keyFingerprint: nil, updatedAt: nil, alarm: nil, backup: true, unlockTtlSeconds: 300,
                criticalItems: 0
            )),
            CredentialState(loading: false, status: status, alarm: alarm, windowUntil: now.addingTimeInterval(600), notice: .backupOff),
        ]
        for s in states {
            #expect(height(CredentialContent(state: s, now: now)) > 0)
        }
        var pw = ChangePasswordState(askPin: true)
        pw.password = "password1234"
        pw.rule = .common
        pw.mismatch = true
        pw.error = .badPin
        var done = ChangePasswordState(askPin: true)
        done.done = true
        var lost = [ChangePasswordState]()
        for check in [ChangeCheck.Status.checking, .unreachable, .notApplied] {
            var l = ChangePasswordState(askPin: true)
            l.check = check
            lost.append(l)
        }
        for s in [pw, done, ChangePasswordState()] + lost {
            #expect(height(ChangePasswordContent(state: s)) > 0)
        }
        #expect(height(BackupOffSheet(onConfirm: {}, onDismiss: {})) > 0)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
