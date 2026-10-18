#if DEBUG
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDSettingsUI

/// Debug only: the name change, the PIN change, the Credential screen and the password change in each of their states
/// (``ShellCatalog``).
extension ShellCatalog {
    static var flowEntries: [Entry] { nameEntries + pinEntries + credentialEntries }

    /// The screen of a flow's entry, with actions that do nothing.
    @MainActor @ViewBuilder
    static func flowScreen(_ screen: Screen) -> some View {
        switch screen {
        case .changeName(let state): ChangeNameContent(state: state, now: now)
        case .changePin(let state): ChangePinContent(state: state)
        case .credential(let state): CredentialContent(state: state, now: now)
        case .changePassword(let state): ChangePasswordContent(state: state)
        default: EmptyView()
        }
    }

    private static var nameEntries: [Entry] {
        var pending = member
        pending.nameRequest = NameRequestView(seq: 4, firstName: "Ada", lastName: "King", requestedAt: now, state: .pending)
        var tooSoon = ChangeNameState(account: member)
        tooSoon.tooSoon = true
        tooSoon.allowedAfter = now.addingTimeInterval(86_400 * 12)
        var invalid = ChangeNameState(account: member)
        invalid.first = "Ada1"
        invalid.last = ""
        invalid.checked = true
        var confirm = ChangeNameState(account: member)
        confirm.last = "King"
        confirm.step = .confirm
        confirm.message = .badPassword(checksLeft: 2)
        var backoff = confirm
        backoff.message = .backoff
        backoff.waitSeconds = 75
        return [
            Entry(id: "sheet_name_pending", title: "Avatar sheet: name change requested", screen: .accountSheet(pending)),
            Entry(id: "name_names", title: "Change name: names", screen: .changeName(ChangeNameState(account: member))),
            Entry(id: "name_too_soon", title: "Change name: too soon", screen: .changeName(tooSoon)),
            Entry(id: "name_invalid", title: "Change name: names refused", screen: .changeName(invalid)),
            Entry(id: "name_confirm", title: "Change name: wrong password", screen: .changeName(confirm)),
            Entry(id: "name_backoff", title: "Change name: backoff", screen: .changeName(backoff)),
            Entry(id: "name_pending", title: "Change name: requested", screen: .changeName(sent(.pending))),
            Entry(id: "name_applied", title: "Change name: applied", screen: .changeName(sent(.applied))),
            Entry(id: "name_refused", title: "Change name: refused", screen: .changeName(sent(.refused, reason: "invalid"))),
        ]
    }

    private static func sent(_ state: NameRequestState, reason: String? = nil) -> ChangeNameState {
        var s = ChangeNameState(account: member)
        s.last = "King"
        s.step = .sent
        s.request = NameRequestView(seq: 4, firstName: "Ada", lastName: "King", requestedAt: now, state: state, reason: reason)
        return s
    }

    private static var pinEntries: [Entry] {
        var problem = ChangePinState(withPassword: true)
        problem.step = .new
        problem.problem = .sequence
        var confirm = ChangePinState(withPassword: true)
        confirm.step = .confirm
        confirm.mismatch = true
        var failed = ChangePinState(withPassword: true)
        failed.error = .badPin
        var unanswered = ChangePinState(withPassword: true)
        unanswered.error = .noResponse
        unanswered.mayHaveChanged = true
        var done = ChangePinState(withPassword: true)
        done.done = true
        return [
            Entry(id: "pin_unanswered", title: "Change PIN: no answer", screen: .changePin(unanswered)),
            Entry(id: "pin_current", title: "Change PIN: current", screen: .changePin(ChangePinState(withPassword: true))),
            Entry(id: "pin_attempts", title: "Change PIN: after recovery attempts", screen: .changePin(
                ChangePinState(withPassword: true, fromAttempts: true)
            )),
            Entry(id: "pin_problem", title: "Change PIN: a weak PIN", screen: .changePin(problem)),
            Entry(id: "pin_confirm", title: "Change PIN: mismatch, password", screen: .changePin(confirm)),
            Entry(id: "pin_failed", title: "Change PIN: wrong PIN", screen: .changePin(failed)),
            Entry(id: "pin_done", title: "Change PIN: done", screen: .changePin(done)),
        ]
    }

    private static var credentialEntries: [Entry] {
        let status = CredentialStatus(
            exists: true, version: 4, keyFingerprint: "k1-012345678", updatedAt: "2026-10-04T12:00:00Z", alarm: nil, backup: true,
            unlockTtlSeconds: 300, criticalItems: 2
        )
        var off = status
        off.backup = false
        let alarm = CredentialAlarm(alarmID: "01J0000000000000000000000A", state: CredentialAlarm.stateFrozen, at: nil)
        var dialog = CredentialState(loading: false, status: status)
        dialog.windowDialog = true
        dialog.windowError = .badPassword
        var weak = ChangePasswordState(askPin: true)
        weak.password = "password1234"
        weak.rule = .common
        var done = ChangePasswordState(askPin: true)
        done.done = true
        let none = CredentialStatus(
            exists: false, version: nil, keyFingerprint: nil, updatedAt: nil, alarm: nil, backup: true, unlockTtlSeconds: 300,
            criticalItems: nil
        )
        return [
            Entry(id: "credential", title: "Credential", screen: .credential(CredentialState(loading: false, status: status))),
            Entry(id: "credential_window", title: "Credential: window open, backup off", screen: .credential(CredentialState(
                loading: false, status: off, windowUntil: now.addingTimeInterval(240), notice: .backupOff
            ))),
            Entry(id: "credential_alarm", title: "Credential: alarm", screen: .credential(CredentialState(
                loading: false, status: status, alarm: alarm
            ))),
            Entry(id: "credential_dialog", title: "Credential: window password", screen: .credential(dialog)),
            Entry(id: "credential_loading", title: "Credential: loading", screen: .credential(CredentialState())),
            Entry(id: "credential_failed", title: "Credential: failed", screen: .credential(
                CredentialState(loading: false, error: .network)
            )),
            Entry(id: "credential_none", title: "Credential: none yet", screen: .credential(CredentialState(loading: false, status: none))),
            Entry(id: "password", title: "Change password", screen: .changePassword(ChangePasswordState(askPin: true))),
            Entry(id: "password_weak", title: "Change password: a common password", screen: .changePassword(weak)),
            Entry(id: "password_done", title: "Change password: done", screen: .changePassword(done)),
        ]
    }
}
#endif
