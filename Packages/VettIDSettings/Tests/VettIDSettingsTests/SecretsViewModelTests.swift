import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// New phone secret (`vault.secret.renew`, VAULT-MESSAGING §11.14.9) and Delete vault (`vault.delete`, §12.5). Mirrors
/// vettid-android `ReleaseRSettingsTest`'s new-phone-secret part and `SettingsViewModelsTest`'s deletion part.
@MainActor
@Suite struct SecretsViewModelTests {
    let repo: FakeVaultRepository

    init() {
        repo = FakeVaultRepository(.unlocked)
        repo.phoneSecret = true
    }

    // MARK: - New phone secret

    /// vettid-android `newPhoneSecret`: the PIN and the password go together; done drops both.
    @Test func aNewPhoneSecret() async {
        let m = NewPhoneSecretViewModel(vault: repo)
        m.setPin("975310")
        #expect(!m.state.canSubmit(pinTyped: 6), "no password yet")
        m.setPassword("the password")
        #expect(!m.state.canSubmit(pinTyped: 5) && m.state.canSubmit(pinTyped: 6))
        m.submit()
        #expect(m.state.busy)
        await m.settle()
        #expect(m.state.done && m.state.pin.isEmpty && m.state.password.isEmpty)
        #expect(repo.lastRenew?.pin == "975310" && repo.lastRenew?.password == "the password")
    }

    /// vettid-android `newPhoneSecretRefusedKeepsNothing`: a refusal is shown, and neither entry is kept.
    @Test func aRefusalKeepsNothing() async {
        repo.fail["renewPhoneSecret"] = VaultFailure(.badPassword, code: "bad_password")
        let m = NewPhoneSecretViewModel(vault: repo)
        m.setPin("975310")
        m.setPassword("wrong")
        m.submit()
        await m.settle()
        #expect(m.state.error == .badPassword && !m.state.done)
        #expect(m.state.pin.isEmpty && m.state.password.isEmpty)
    }

    /// A lost answer (``FailureKind/noResponse``) is shown as Android shows it: the phone's record decides, and "Try again"
    /// sends the same secret (IOS-PLAN §6.3).
    @Test func aLostAnswerIsShownAndCanBeTriedAgain() async {
        repo.fail["renewPhoneSecret"] = VaultFailure(.noResponse)
        let m = NewPhoneSecretViewModel(vault: repo)
        m.setPin("975310")
        m.setPassword("pw")
        m.submit()
        await m.settle()
        #expect(m.state.error == .noResponse)
        m.setPin("975310")
        m.setPassword("pw")
        m.submit()
        await m.settle()
        #expect(m.state.done && repo.calls.filter { $0 == "renewPhoneSecret" }.count == 2)
    }

    /// The app leaving the foreground drops what was typed (IOS-PLAN §6.3).
    @Test func typedSecretsAreForgotten() {
        let m = NewPhoneSecretViewModel(vault: repo)
        m.setPin("975310")
        m.setPassword("pw")
        m.forgetSecrets()
        #expect(m.state.pin.isEmpty && m.state.password.isEmpty)
        #expect(!"\(m.state)".contains("975310") && !String(reflecting: m.state).contains("pw"))
    }

    // MARK: - Delete vault

    /// vettid-android `deleteNeedsPhrasePinPasswordAcknowledgementAndFinalConfirmation`.
    @Test func deleteNeedsPhrasePinPasswordAcknowledgementAndFinalConfirmation() async {
        let m = DeleteVaultViewModel(vault: repo)
        m.setPhrase("Delete my vault")
        m.setPin("40281795")
        m.setPassword("pw")
        m.setAcknowledged(true)
        #expect(!m.state.ready(pinTyped: m.state.pin.count))
        m.submit()
        #expect(m.state.phraseWrong)
        m.setPhrase("delete my vault")
        m.submit()
        #expect(m.state.confirming)
        #expect(!repo.calls.contains("deleteVault"))
        m.confirm()
        await m.settle()
        #expect(repo.phase == .signedOut && repo.lastPin == "40281795" && repo.lastPassword == "pw")
    }

    /// Each of the phrase, a PIN of 4 digits at least, the password and the acknowledgement is needed.
    @Test func everyPartIsNeeded() {
        var s = DeleteVaultState()
        s.phrase = "  delete my vault "
        s.password = "pw"
        s.acknowledged = true
        #expect(s.ready(pinTyped: 4) && !s.ready(pinTyped: 3))
        s.acknowledged = false
        #expect(!s.ready(pinTyped: 6))
        s.acknowledged = true
        s.password = ""
        #expect(!s.ready(pinTyped: 6))
    }

    /// A refusal is shown; the PIN and the password go (vettid-android clears both); the phrase stays.
    @Test func aRefusalClearsTheSecrets() async {
        repo.fail["deleteVault"] = VaultFailure(.badPin, code: "bad_pin")
        let m = filled()
        m.confirm()
        await m.settle()
        #expect(m.state.error == .badPin && !m.state.busy && m.state.pin.isEmpty && m.state.password.isEmpty)
        #expect(m.state.phrase == "delete my vault" && repo.phase == .unlocked)
    }

    /// VAULT-MESSAGING 0.54.0 §10.2: `credential_required{no_holder}` (a vault with no holder) is a refusal like the others
    /// here: the PIN and the password go, nothing is deleted; the root screen "This phone can't use your vault" is the
    /// vault manager's (IOS-PLAN §4.4 (1)).
    @Test func noHolderClearsTheSecrets() async {
        repo.fail["deleteVault"] = VaultFailure(.credentialRequired, code: "credential_required")
        let m = filled()
        m.confirm()
        await m.settle()
        #expect(m.state.error == .credentialRequired && !m.state.busy && m.state.pin.isEmpty && m.state.password.isEmpty)
        #expect(!m.state.unconfirmed && !m.state.notDeleted && repo.phase == .unlocked)
    }

    /// The final confirmation cancelled: nothing is sent, and the PIN goes with it (the keypad shows none).
    @Test func cancellingTheConfirmationSendsNothing() {
        let m = filled()
        m.cancelConfirm()
        #expect(!m.state.confirming && m.state.pin.isEmpty && !repo.calls.contains("deleteVault"))
        m.confirm()
        #expect(!repo.calls.contains("deleteVault"), "no PIN: nothing to send")
    }

    /// A lost answer the account service does not yet show as done: said so, nothing else; "Check again" asks the
    /// account service (nothing to the vault) until it shows the vault gone.
    @Test func aLostAnswerIsCheckedAgain() async {
        repo.fail["deleteVault"] = VaultFailure(.noResponse, code: VaultManager.codeDeleteUnconfirmed)
        let m = filled()
        m.confirm()
        await m.settle()
        #expect(m.state.unconfirmed && m.state.error == nil && m.state.pin.isEmpty)
        m.checkAgain()
        await m.settle()
        #expect(m.state.unconfirmed && repo.phase == .unlocked)
        repo.deletionCheck = .deleted
        m.checkAgain()
        await m.settle()
        #expect(!m.state.unconfirmed && repo.phase == .signedOut)
        #expect(repo.calls.filter { $0 == "deleteVault" }.count == 1)
    }

    /// Past the request's `exp` with the vault still listed: "not deleted", said definitely; a new try clears both notices.
    @Test func aLostAnswerFoundNotDeletedIsSaidSo() async {
        repo.fail["deleteVault"] = VaultFailure(.noResponse, code: VaultManager.codeDeleteUnconfirmed)
        let m = filled()
        m.confirm()
        await m.settle()
        repo.deletionCheck = .notDeleted
        m.checkAgain()
        await m.settle()
        #expect(m.state.notDeleted && !m.state.unconfirmed && repo.phase == .unlocked)
        m.setPin("40281795")
        m.setPassword("pw")
        m.submit()
        m.confirm()
        #expect(!m.state.notDeleted && !m.state.unconfirmed && m.state.busy)
        await m.settle()
        #expect(repo.phase == .signedOut)
    }

    /// The app leaving the foreground drops the PIN, the password and the final confirmation.
    @Test func typedSecretsAreForgottenOnDelete() {
        let m = filled()
        m.forgetSecrets()
        #expect(m.state.pin.isEmpty && m.state.password.isEmpty && !m.state.confirming)
        #expect(!"\(m.state)".contains("40281795"))
    }

    /// The deletion ready and its final confirmation shown.
    private func filled() -> DeleteVaultViewModel {
        let m = DeleteVaultViewModel(vault: repo)
        m.setPhrase("delete my vault")
        m.setPin("40281795")
        m.setPassword("pw")
        m.setAcknowledged(true)
        m.submit()
        #expect(m.state.confirming)
        return m
    }
}
