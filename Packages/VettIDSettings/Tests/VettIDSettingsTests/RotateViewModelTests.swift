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
        let m = NewCredentialViewModel(repo: repo)
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
        let m = NewCredentialViewModel(repo: repo)
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
        let m = NewCredentialViewModel(repo: repo)
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

    /// Polls the main actor until [condition] holds (at most 2 s).
    func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
