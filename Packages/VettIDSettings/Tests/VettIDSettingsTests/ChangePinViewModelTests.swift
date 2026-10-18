import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDSettings

/// `pin.change` (VAULT-MESSAGING §10.6, §11.14.9) through the iPhone's keypad steps: the same checks as vettid-android in
/// the same order (the rules, "different", the confirmation), the password of release R, and a failure that starts again
/// from the current PIN. Mirrors vettid-android `SettingsViewModelsTest`'s PIN part.
@MainActor
@Suite struct ChangePinViewModelTests {
    let repo: FakeVaultRepository

    init() {
        repo = FakeVaultRepository(.unlocked)
        repo.phoneSecret = true
    }

    /// The current PIN typed and taken.
    func atNew(_ m: ChangePinViewModel) {
        m.setCurrent("40281795")
        m.next()
    }

    @Test func changePinChecksPolicyAndConfirmation() async {
        let m = ChangePinViewModel(vault: repo)
        #expect(m.state.withPassword && m.state.step == .current)
        m.next()
        #expect(m.state.step == .current, "nothing typed: no step")
        atNew(m)
        #expect(m.state.step == .new)
        m.setPin("111111")
        m.next()
        #expect(m.state.problem == .repeated && m.state.step == .new && m.state.pin.isEmpty)
        m.setPin("40281795")
        m.next()
        #expect(m.state.same && m.state.step == .new)
        m.setPin("59173048")
        m.next()
        #expect(m.state.step == .confirm && m.state.problem == nil && !m.state.same)
        m.setConfirm("59173049")
        m.setPassword("correct horse")
        m.next()
        #expect(m.state.mismatch && m.state.confirm.isEmpty && m.state.step == .confirm)
        m.setConfirm("59173048")
        m.submit()
        await m.settle()
        #expect(m.state.done)
        #expect(repo.lastPin == "59173048" && repo.lastPinChange?.pin == "40281795" && repo.lastPinChange?.password == "correct horse")
        #expect(m.state.current.isEmpty && m.state.pin.isEmpty && m.state.password.isEmpty)
    }

    /// Release R: without the password nothing is sent.
    @Test func thePasswordGoesWithTheChange() async {
        let m = ChangePinViewModel(vault: repo)
        atNew(m)
        m.setPin("59173048")
        m.next()
        m.setConfirm("59173048")
        m.submit()
        await m.settle()
        #expect(!repo.calls.contains("changePin") && !m.state.done)
    }

    @Test func aFailureIsReportedAndEverythingIsTypedAgain() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.badPin, code: "bad_pin")
        let m = ChangePinViewModel(vault: repo, fromAttempts: true)
        atNew(m)
        m.setPin("59173048")
        m.next()
        m.setConfirm("59173048")
        m.setPassword("pw")
        m.next()
        await m.settle()
        #expect(m.state.error == .badPin && m.state.step == .current && m.state.fromAttempts)
        #expect(m.state.current.isEmpty && m.state.pin.isEmpty && m.state.confirm.isEmpty && m.state.password.isEmpty)
        #expect(!"\(m.state)".contains("59173048"))
    }

    /// No answer: the PIN may already be the new one (the iPhone's text); the new PIN is kept, so after the current PIN the
    /// same new PIN is only confirmed and sent again.
    @Test func noAnswerKeepsTheNewPin() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.noResponse, code: VaultManager.codeChangeUnanswered)
        let m = ChangePinViewModel(vault: repo)
        atNew(m)
        m.setPin("59173048")
        m.next()
        m.setConfirm("59173048")
        m.setPassword("pw")
        m.next()
        await m.settle()
        #expect(m.state.mayHaveChanged && m.state.error == .noResponse && m.state.step == .current)
        #expect(m.state.pin == "59173048" && m.state.current.isEmpty && m.state.password.isEmpty)
        atNew(m)
        #expect(m.state.step == .confirm)
        m.setConfirm("59173048")
        m.setPassword("pw")
        m.next()
        await m.settle()
        #expect(m.state.done && repo.lastPin == "59173048")
    }

    /// A wrong PIN keeps nothing.
    @Test func aWrongPinKeepsNothing() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.badPin, code: "bad_pin")
        let m = ChangePinViewModel(vault: repo)
        atNew(m)
        m.setPin("59173048")
        m.next()
        m.setConfirm("59173048")
        m.setPassword("pw")
        m.next()
        await m.settle()
        #expect(!m.state.mayHaveChanged && m.state.pin.isEmpty)
    }

    /// Leaving while the change is on its way drops the secrets and stays busy: nothing can be sent twice.
    @Test func forgettingWhileBusyStaysBusy() async {
        let m = ChangePinViewModel(vault: repo)
        atNew(m)
        m.setPin("59173048")
        m.next()
        m.setConfirm("59173048")
        m.setPassword("pw")
        m.next()
        #expect(m.state.busy)
        m.forgetSecrets()
        #expect(m.state.busy && m.state.current.isEmpty && m.state.pin.isEmpty && m.state.password.isEmpty)
        m.submit()
        await m.settle()
        #expect(repo.calls.filter { $0 == "changePin" }.count == 1 && m.state.done)
    }

    @Test func backGoesOneStepAndForgetsIt() {
        let m = ChangePinViewModel(vault: repo)
        atNew(m)
        m.setPin("59173048")
        m.next()
        m.setPassword("pw")
        m.back()
        #expect(m.state.step == .new && m.state.pin.isEmpty && m.state.password.isEmpty && m.state.current == "40281795")
        m.back()
        #expect(m.state.step == .current && m.state.current.isEmpty)
        atNew(m)
        m.forgetSecrets()
        #expect(m.state == ChangePinState(withPassword: true))
    }
}
