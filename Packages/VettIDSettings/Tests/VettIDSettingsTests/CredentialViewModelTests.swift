import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings
@testable import VettIDVault

/// The Credential screen and the password change (VAULT-MESSAGING §3.5, §10.6, §11.14.9). Mirrors vettid-android
/// `CredentialViewModelsTest` (the rotation and the clone alarm: ``RotateViewModelTests``).
@MainActor
@Suite struct CredentialViewModelTests {
    let repo = FakeVaultRepository(.unlocked)

    @Test func loadsStatusOpensAndClosesTheWindowAndSetsTheBackup() async {
        let m = CredentialViewModel(repo: repo)
        #expect(m.state.loading)
        await m.settle()
        #expect(m.state.status?.version == 2 && !m.state.loading)
        m.showWindowDialog(true)
        m.setWindowPassword("pw")
        m.openWindow()
        await m.settle()
        #expect(m.state.windowUntil != nil && !m.state.windowDialog && repo.lastPassword == "pw")
        m.closeWindow()
        await m.settle()
        #expect(m.state.windowUntil == nil)
        m.setBackup(false)
        await m.settle()
        #expect(repo.lastBackup == false && m.state.notice == .backupOff && m.state.status?.backup == false)
        m.setTtl(900)
        await m.settle()
        #expect(m.state.status?.unlockTtlSeconds == 900)
        m.dismissNotice()
        #expect(m.state.notice == nil)
    }

    @Test func wrongPasswordKeepsTheDialogOpen() async {
        let m = CredentialViewModel(repo: repo)
        await m.settle()
        repo.fail["openUnlockWindow"] = FakeVaultRepository.failure(.badPassword, code: "bad_password")
        m.showWindowDialog(true)
        m.setWindowPassword("wrong")
        m.openWindow()
        await m.settle()
        #expect(m.state.windowDialog && m.state.windowError == .badPassword && m.state.windowPassword.isEmpty)
    }

    @Test func aFailedLoadSaysWhyAndLoadsAgain() async {
        repo.fail["status"] = FakeVaultRepository.failure(.network)
        let m = CredentialViewModel(repo: repo)
        await m.settle()
        #expect(m.state.status == nil && m.state.error == .network && !m.state.loading)
        m.refresh()
        await m.settle()
        #expect(m.state.status != nil && m.state.error == nil)
    }

    /// The alarm and the window are the repository's.
    @Test func theAlarmIsTheRepositorys() async {
        let m = CredentialViewModel(repo: repo)
        repo.alarm = CredentialAlarm(alarmID: "01J0000000000000000000000A", state: CredentialAlarm.stateFrozen, at: nil)
        #expect(m.state.alarm?.frozen == true)
    }

    // MARK: - The password change

    /// Release R (VAULT-MESSAGING §11.14.9): the password change asks for the PIN and carries it.
    @Test func releaseRPasswordChangeCarriesThePin() async {
        repo.phoneSecret = true
        let m = ChangePasswordViewModel(repo: repo, vault: repo)
        #expect(m.state.askPin)
        m.setCurrent("old password 1")
        m.setPassword("a much better passphrase here")
        m.setConfirm("a much better passphrase here")
        m.submit()
        await m.settle()
        #expect(!repo.calls.contains("changePassword"), "without the PIN nothing is sent")
        m.setPin("975310")
        m.submit()
        await m.settle()
        #expect(m.state.done && repo.lastPasswordChangePin == "975310" && repo.lastPassword == "a much better passphrase here")
    }

    /// The rules as the member types, the same password, a mismatch, and the vault's weak_password reason.
    @Test func releaseRPasswordChangeFollowsTheRules() async {
        repo.phoneSecret = true
        let m = ChangePasswordViewModel(repo: repo, vault: repo)
        m.setPin("975310")
        m.setCurrent("old password 1")
        m.setPassword("password1234")
        m.setConfirm("password1234")
        #expect(m.state.rule == .common && !m.state.canSubmit(pinTyped: 0))
        m.submit()
        await m.settle()
        #expect(!repo.calls.contains("changePassword"))
        m.setPin("975310")
        m.setPassword("975310975310")
        #expect(!m.state.canSubmit(pinTyped: 0))
        m.setPassword("old password 1")
        m.setConfirm("old password 1")
        m.setPin("975310")
        m.submit()
        #expect(m.state.same)
        m.setPassword("a much better passphrase here")
        m.setConfirm("a much better passphrase her")
        m.setPin("975310")
        m.submit()
        #expect(m.state.mismatch)
        m.setConfirm("a much better passphrase here")
        #expect(m.state.rule == .ok)
        repo.fail["changePassword"] = VaultFailure(
            .weakPassword, code: "weak_password",
            cause: VaultOpError(
                type: "credential.password.change", code: "weak_password", detail: "", body: Array(#"{"reason":"common"}"#.utf8)
            )
        )
        m.setPin("975310")
        m.submit()
        await m.settle()
        #expect(m.state.rule == .common && m.state.refused && m.state.error == nil && !m.state.done)
        #expect(m.state.current.isEmpty && m.state.pin.isEmpty)
        m.setPassword("a different passphrase 7")
        #expect(!m.state.refused)
    }

    /// The new password typed with the PIN and sent.
    func sendPassword(_ m: ChangePasswordViewModel) async {
        m.setPin("975310")
        m.setCurrent("old password 1")
        m.setPassword("a much better passphrase here")
        m.setConfirm("a much better passphrase here")
        m.submit()
        await m.settle()
    }

    /// VAULT-MESSAGING §11.14.9 "A lost answer": no answer is no failure; leaving meanwhile stays busy; the new password is
    /// kept while the change is decided, and the decision arrives (applied: the usual success).
    @Test func noAnswerIsCheckedNotFailed() async {
        repo.phoneSecret = true
        repo.fail["changePassword"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.password, .unreachable)
        let m = ChangePasswordViewModel(repo: repo, vault: repo)
        m.setPin("975310")
        m.setCurrent("old password 1")
        m.setPassword("a much better passphrase here")
        m.setConfirm("a much better passphrase here")
        m.submit()
        m.forgetSecrets()
        #expect(m.state.busy && m.state.password.isEmpty)
        await m.settle()
        #expect(m.state.check == .unreachable && m.state.error == nil && !m.state.done)
        repo.fail["changePassword"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        await sendPassword(m)
        #expect(m.state.check == .unreachable && m.state.password == "a much better passphrase here" && m.state.current.isEmpty)
        repo.changeCheck = ChangeCheck(.password, .applied)
        for _ in 0..<100 where !m.state.done { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(m.state.done && repo.changeCheck == nil)
    }

    /// Decided not applied: "not changed", the new password kept.
    @Test func notAppliedKeepsTheNewPassword() async {
        repo.phoneSecret = true
        repo.fail["changePassword"] = FakeVaultRepository.failure(.other, code: VaultManager.codeChangeNotApplied)
        let m = ChangePasswordViewModel(repo: repo, vault: repo)
        await sendPassword(m)
        #expect(m.state.check == .notApplied && m.state.error == nil && m.state.password == "a much better passphrase here")
    }

    /// A refusal decided while the screen waits shows as it is, the wrong entry cleared.
    @Test func aLaterRefusalIsShownAsItIs() async {
        repo.phoneSecret = true
        repo.fail["changePassword"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.password, .checking)
        let m = ChangePasswordViewModel(repo: repo, vault: repo)
        await sendPassword(m)
        repo.changeCheck = ChangeCheck(.password, .refused(.badPassword, code: "bad_password"))
        for _ in 0..<100 where m.state.error == nil { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(m.state.error == .badPassword && m.state.check == nil && m.state.current.isEmpty)
    }

    /// §11.14.9 step 4: a wrong PIN clears the PIN and keeps the passwords.
    @Test func aWrongPinClearsThePin() async {
        repo.phoneSecret = true
        repo.fail["changePassword"] = FakeVaultRepository.failure(.badPin, code: "bad_pin")
        let m = ChangePasswordViewModel(repo: repo, vault: repo)
        await sendPassword(m)
        #expect(m.state.error == .badPin && m.state.pin.isEmpty && m.state.current == "old password 1")
    }

    @Test func aFailureIsShown() async {
        repo.phoneSecret = true
        repo.fail["changePassword"] = FakeVaultRepository.failure(.badPin, code: "bad_pin")
        let m = ChangePasswordViewModel(repo: repo, vault: repo)
        m.setPin("975310")
        m.setCurrent("old password 1")
        m.setPassword("a much better passphrase here")
        m.setConfirm("a much better passphrase here")
        m.submit()
        await m.settle()
        #expect(m.state.error == .badPin && !m.state.done && m.state.pin.isEmpty)
    }
}
