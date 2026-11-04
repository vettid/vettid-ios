import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings
@testable import VettIDVault

/// The rotation, the clone alarm and a new credential (VAULT-MESSAGING §3.5.5, §3.5.9). Mirrors vettid-android
/// `CredentialViewModelsTest` (`RotateViewModel`, `AlarmViewModel`) and `NewCredentialViewModelTest`.
@MainActor
@Suite struct RotateViewModelTests {
    let repo = FakeVaultRepository(.unlocked)

    // MARK: - The rotation

    @Test func rotatesWithThePassword() async {
        repo.rotateOffered = true
        let m = RotateViewModel(repo: repo)
        m.submit()
        #expect(!repo.calls.contains("rotate"), "nothing without the password")
        m.setPassword("pw")
        m.submit()
        await m.settle()
        #expect(repo.lastPassword == "pw" && m.state.done && m.state.password.isEmpty && !repo.rotateOffered)
    }

    @Test func aRefusalSaysWhyAndDropsThePassword() async {
        repo.fail["rotate"] = FakeVaultRepository.failure(.badPassword, code: "bad_password")
        let m = RotateViewModel(repo: repo)
        m.setPassword("wrong")
        m.submit()
        await m.settle()
        #expect(m.state.error == .badPassword && m.state.password.isEmpty && !m.state.done && !m.state.busy)
        m.setPassword("pw")
        #expect(m.state.error == nil)
        m.forgetSecrets()
        #expect(m.state.password.isEmpty)
    }

    /// A rate-limited or backed-off refusal keeps the wait it asked for, for the text.
    @Test func aRateLimitedRefusalKeepsTheWait() async {
        repo.fail["rotate"] = FakeVaultRepository.failure(.rateLimited, retry: 120)
        let m = RotateViewModel(repo: repo)
        m.setPassword("pw")
        m.submit()
        await m.settle()
        #expect(m.state.error == .rateLimited && m.state.waiting)
        let remaining = m.state.errorRetryAt?.remaining() ?? 0
        #expect((90...120).contains(remaining))
        // Held back for the whole wait: a submit during it sends nothing (VAULT-MESSAGING §10.1).
        m.setPassword("pw")
        #expect(m.state.error == .rateLimited, "typing does not clear a wait that runs")
        m.submit()
        await m.settle()
        #expect(repo.calls.filter { $0 == "rotate" }.count == 1)
        // A refusal without a wait has none, and holds nothing back.
        repo.fail["rotate"] = FakeVaultRepository.failure(.badPassword, code: "bad_password")
        let other = RotateViewModel(repo: repo)
        other.setPassword("pw")
        other.submit()
        await other.settle()
        #expect(other.state.error == .badPassword && other.state.errorRetryAt == nil && !other.state.waiting)
    }

    /// The send is held back while a wait runs, on every screen that shows one, and released after (VAULT-MESSAGING §10.1).
    @Test func everyWaitHoldsTheSendBackAndReleasesIt() {
        let running = WaitDeadline(seconds: 600)
        let over = WaitDeadline(seconds: 0)
        var rotate = RotateState(error: .rateLimited, retryAt: running)
        #expect(rotate.waiting)
        rotate.errorRetryAt = over
        #expect(!rotate.waiting)
        var phone = NewPhoneSecretState(error: .backoff, retryAt: running)
        phone.pin = "123456"
        phone.password = "pw"
        #expect(!phone.canSubmit(pinTyped: 6))
        phone.errorRetryAt = over
        #expect(phone.canSubmit(pinTyped: 6))
        var delete = DeleteVaultState()
        delete.phrase = "delete my vault"
        delete.password = "pw"
        delete.acknowledged = true
        delete.errorRetryAt = running
        #expect(delete.waiting && !delete.ready(pinTyped: 6))
        delete.errorRetryAt = over
        #expect(delete.ready(pinTyped: 6))
        var pin = ChangePinState()
        pin.errorRetryAt = running
        #expect(pin.waiting)
        var credential = NewCredentialState()
        credential.errorRetryAt = running
        #expect(credential.waiting)
        var window = CredentialState()
        window.windowRetryAt = running
        #expect(window.windowWaiting)
        window.windowRetryAt = over
        #expect(!window.windowWaiting)
        // Typing does not clear a failure whose wait runs; it clears one whose wait is over.
        rotate.errorRetryAt = running
        rotate.clearError()
        #expect(rotate.error == .rateLimited)
        rotate.errorRetryAt = over
        rotate.clearError()
        #expect(rotate.error == nil)
    }

    // MARK: - The clone alarm

    func frozen() -> CredentialAlarm { CredentialAlarm(alarmID: "a1", state: CredentialAlarm.stateFrozen, at: "2026-10-04T12:00:00Z") }

    /// "Not me", confirmed: `rotation_required`, then the rotation resolves it; the advice stays.
    @Test func notMineThenTheRotationResolvesIt() async {
        repo.alarm = frozen()
        let m = AlarmViewModel(repo: repo)
        #expect(m.state.step == .ask)
        m.answer(mine: false)
        #expect(m.state.step == .confirmNotMine && m.state.notMine)
        m.cancelAnswer()
        #expect(m.state.step == .ask)
        m.answer(mine: false)
        m.confirm()
        await m.settle()
        #expect(repo.lastAlarmMine == false && m.state.step == .rotate)
        m.setPassword("pw")
        m.rotate()
        await m.settle()
        #expect(m.state.step == .resolved && m.state.notMine && m.state.password.isEmpty && repo.alarm == nil)
    }

    /// "That was me": the same rotation follows.
    @Test func mineAlsoRotates() async {
        repo.alarm = frozen()
        let m = AlarmViewModel(repo: repo)
        m.answer(mine: true)
        #expect(m.state.step == .confirmMine && !m.state.notMine)
        m.confirm()
        await m.settle()
        #expect(repo.lastAlarmMine == true && m.state.step == .rotate)
    }

    /// An alarm that already waits for the rotation opens on it; a failed confirmation goes back to the question.
    @Test func theStepFollowsTheAlarm() async {
        repo.alarm = CredentialAlarm(alarmID: "a1", state: CredentialAlarm.stateRotationRequired, at: nil)
        #expect(AlarmViewModel(repo: repo).state.step == .rotate)
        #expect(AlarmState.step(for: nil) == .resolved)
        repo.alarm = frozen()
        repo.fail["confirmAlarm"] = FakeVaultRepository.failure(.network)
        let m = AlarmViewModel(repo: repo)
        m.answer(mine: true)
        m.confirm()
        await m.settle()
        #expect(m.state.step == .ask && m.state.error == .network)
    }

    /// Another device answered or rotated: the screen follows the repository's alarm.
    @Test func anotherDevicesAnswerMovesTheScreen() async {
        repo.alarm = frozen()
        let m = AlarmViewModel(repo: repo)
        repo.alarm?.state = CredentialAlarm.stateRotationRequired
        #expect(await until { m.state.step == .rotate })
        repo.alarm = nil
        #expect(await until { m.state.step == .resolved })
    }

    @Test func aWrongPasswordKeepsTheRotationStep() async {
        repo.alarm = CredentialAlarm(alarmID: "a1", state: CredentialAlarm.stateRotationRequired, at: nil)
        repo.fail["rotate"] = FakeVaultRepository.failure(.badPassword, code: "bad_password")
        let m = AlarmViewModel(repo: repo)
        m.setPassword("wrong")
        m.rotate()
        await m.settle()
        #expect(m.state.step == .rotate && m.state.error == .badPassword && m.state.password.isEmpty)
    }

    // MARK: - A new credential

    func filled(_ m: NewCredentialViewModel) {
        m.setPin("975310")
        m.setCurrent("old password 1")
        m.setPassword("a much better passphrase here")
        m.setConfirm("a much better passphrase here")
        m.setAcknowledged(true)
    }

    /// The form, the final confirmation, then the reset with the PIN, the current password and the new one.
    @Test func aNewCredentialIsConfirmedThenSent() async {
        let m = NewCredentialViewModel(repo: repo, vault: repo)
        filled(m)
        m.setAcknowledged(false)
        #expect(!m.state.filled(pinTyped: 0))
        m.setAcknowledged(true)
        m.submit()
        #expect(m.state.confirming && !repo.calls.contains("newCredential"))
        m.confirm()
        await m.settle()
        #expect(repo.lastPin == "975310" && repo.lastPassword == "old password 1")
        #expect(repo.lastNewPassword == "a much better passphrase here")
        #expect(m.state.done && m.state.pin.isEmpty && m.state.current.isEmpty && m.state.password.isEmpty)
    }

    /// A mismatch is said before the confirmation; a cancelled confirmation drops the PIN.
    @Test func aMismatchAndACancel() async {
        let m = NewCredentialViewModel(repo: repo, vault: repo)
        filled(m)
        m.setConfirm("a much better passphrase her")
        m.submit()
        #expect(m.state.mismatch && !m.state.confirming && m.state.pin.isEmpty)
        m.setConfirm("a much better passphrase here")
        m.setPin("975310")
        m.submit()
        m.cancelConfirm()
        #expect(!m.state.confirming && m.state.pin.isEmpty)
        m.confirm()
        await m.settle()
        #expect(!repo.calls.contains("newCredential"))
    }

    /// A refusal clears the PIN and the current password; `weak_password` shows its reason under the new password.
    @Test func refusalsClearTheSecretsThatWereChecked() async {
        let m = NewCredentialViewModel(repo: repo, vault: repo)
        repo.fail["newCredential"] = FakeVaultRepository.failure(.badPin, code: "bad_pin")
        filled(m)
        m.submit()
        m.confirm()
        await m.settle()
        #expect(m.state.error == .badPin && m.state.pin.isEmpty && m.state.current.isEmpty && !m.state.password.isEmpty)
        repo.fail["newCredential"] = VaultFailure(
            .weakPassword, code: "weak_password",
            cause: VaultOpError(type: "credential.reset", code: "weak_password", detail: "", body: Array(#"{"reason":"common"}"#.utf8))
        )
        filled(m)
        m.submit()
        m.confirm()
        await m.settle()
        #expect(m.state.rule == .common && m.state.refused && m.state.error == nil && !m.state.done)
        m.forgetSecrets()
        #expect(m.state.password.isEmpty && m.state.confirm.isEmpty && !m.state.refused)
    }

    /// IOS-PLAN 0.1.9 §6.3: New credential is offered again, now that a lost answer to it is decided.
    @Test func theNewCredentialRowIsShown() {
        #expect(CredentialState.offersNewCredential)
    }

    /// VAULT-MESSAGING 0.48.0 §11.14.9 "A lost answer to `credential.reset`": no answer is no failure; the form says it is
    /// checking, nothing typed is kept, and the decision arrives (applied: the usual success, acknowledged).
    @Test func aResetWithoutAnAnswerIsCheckedNotFailed() async {
        repo.fail["newCredential"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.reset, .unreachable)
        let m = NewCredentialViewModel(repo: repo, vault: repo)
        filled(m)
        m.submit()
        m.confirm()
        await m.settle()
        #expect(m.state.check == .unreachable && m.state.error == nil && !m.state.done && !m.state.busy)
        #expect(m.state.pin.isEmpty && m.state.current.isEmpty && m.state.password.isEmpty)
        repo.changeCheck = ChangeCheck(.reset, .checking)
        #expect(await until { m.state.check == .checking })
        repo.changeCheck = ChangeCheck(.reset, .applied)
        #expect(await until { m.state.done })
        #expect(repo.changeCheck == nil && m.state.check == nil)
    }

    /// Decided not applied (`stale_credential`, or the same key and version after `exp`): said on the form, nothing kept.
    @Test func aResetNotAppliedIsSaid() async {
        repo.fail["newCredential"] = FakeVaultRepository.failure(.other, code: VaultManager.codeChangeNotApplied)
        let m = NewCredentialViewModel(repo: repo, vault: repo)
        filled(m)
        m.submit()
        m.confirm()
        await m.settle()
        #expect(m.state.check == .notApplied && m.state.error == nil && !m.state.done && m.state.password.isEmpty)
    }

    /// A refusal decided while the form waits is shown as it is; a password change's decision is not this form's.
    @Test func aLaterRefusalOfTheResetIsShown() async {
        repo.fail["newCredential"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.reset, .checking)
        let m = NewCredentialViewModel(repo: repo, vault: repo)
        filled(m)
        m.submit()
        m.confirm()
        await m.settle()
        repo.changeCheck = ChangeCheck(.password, .applied)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!m.state.done && m.state.check == .checking)
        repo.changeCheck = ChangeCheck(.reset, .refused(.badPassword, code: "bad_password"))
        #expect(await until { m.state.error == .badPassword })
        #expect(m.state.check == nil && !m.state.done)
    }

    /// VAULT-MESSAGING 0.51.1; IOS-PLAN 0.1.13: another phone became the holder while the reset was decided: the form
    /// says so, with nothing kept.
    @Test func anotherHolderEndsTheWait() async {
        repo.fail["newCredential"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.reset, .checking)
        let m = NewCredentialViewModel(repo: repo, vault: repo)
        filled(m)
        m.submit()
        m.confirm()
        await m.settle()
        repo.changeCheck = ChangeCheck(.reset, .notHolder)
        #expect(await until { m.state.check == .notHolder })
        #expect(!m.state.done && m.state.error == nil && m.state.password.isEmpty && repo.changeCheck == nil)
    }

    /// A reset ended by the vault's `forbidden` in its own answer (its check `.notHolder` when it fails): "Your vault moved
    /// to a new phone" is shown once, as the notice, with no failure card. Then a reset refused before it is sent because
    /// a renew decided first was answered `forbidden` (the vault manager sets a PIN change's check `.notHolder` and fails
    /// the reset with `.notHolder`): the failure card shows it once, and that check is acknowledged so that the shell's
    /// notice does not repeat it.
    @Test func anotherHolderIsShownOnce() async {
        repo.fail["newCredential"] = FakeVaultRepository.failure(.notHolder, code: VaultManager.codeNotHolder)
        repo.changeCheck = ChangeCheck(.reset, .notHolder)
        let m = NewCredentialViewModel(repo: repo, vault: repo)
        filled(m)
        m.submit()
        m.confirm()
        await m.settle()
        #expect(m.state.check == .notHolder && m.state.error == nil && repo.changeCheck == nil)
        repo.fail["newCredential"] = FakeVaultRepository.failure(.notHolder, code: VaultManager.codeNotHolder)
        repo.changeCheck = ChangeCheck(.pin, .notHolder)
        let renewing = NewCredentialViewModel(repo: repo, vault: repo)
        filled(renewing)
        renewing.submit()
        renewing.confirm()
        await renewing.settle()
        #expect(renewing.state.error == .notHolder && renewing.state.check == nil)
        #expect(repo.changeCheck == nil)
    }

    /// Polls the main actor until [condition] holds (at most 20 s).
    func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
