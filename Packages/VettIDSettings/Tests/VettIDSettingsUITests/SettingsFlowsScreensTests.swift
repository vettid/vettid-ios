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
        #expect(PinStrings.pinUnanswered.hasPrefix("Your vault did not answer, so your PIN may already be the new one."))
        #expect(CredentialStrings.passwordUnanswered.hasPrefix("Your vault did not answer, so your password may already be the new one."))
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
        var unanswered = ChangePinState(withPassword: true)
        unanswered.error = .noResponse
        unanswered.mayHaveChanged = true
        states.append(unanswered)
        var done = ChangePinState(withPassword: true)
        done.done = true
        states.append(done)
        for s in states {
            #expect(height(ChangePinContent(state: s)) > 0)
        }
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
        for s in [pw, done, ChangePasswordState()] {
            #expect(height(ChangePasswordContent(state: s)) > 0)
        }
        #expect(height(BackupOffSheet(onConfirm: {}, onDismiss: {})) > 0)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}
#endif
