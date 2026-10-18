import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings
@testable import VettIDVault

/// The Credential screen and the password change (VAULT-MESSAGING §3.5, §10.6, §11.14.9). Mirrors vettid-android
/// `CredentialViewModelsTest` (the rotation and the clone alarm come with their screens).
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

    /// No answer: the password may already be the new one (the iPhone's text); leaving meanwhile stays busy.
    @Test func noAnswerMayHaveChanged() async {
        repo.phoneSecret = true
        repo.fail["changePassword"] = FakeVaultRepository.failure(.noResponse, code: VaultManager.codeChangeUnanswered)
        let m = ChangePasswordViewModel(repo: repo, vault: repo)
        m.setPin("975310")
        m.setCurrent("old password 1")
        m.setPassword("a much better passphrase here")
        m.setConfirm("a much better passphrase here")
        m.submit()
        m.forgetSecrets()
        #expect(m.state.busy && m.state.password.isEmpty)
        await m.settle()
        #expect(m.state.mayHaveChanged && m.state.error == .noResponse && !m.state.done)
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
        #expect(m.state.error == .badPin && !m.state.done && m.state.current.isEmpty && m.state.pin.isEmpty)
    }
}
