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

    /// The new PIN typed, confirmed, with the password, and sent.
    func send(_ m: ChangePinViewModel) async {
        atNew(m)
        m.setPin("59173048")
        m.next()
        m.setConfirm("59173048")
        m.setPassword("pw")
        m.next()
        await m.settle()
    }

    @Test func aFailureIsReportedAndEverythingIsTypedAgain() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.retry, code: "retry")
        let m = ChangePinViewModel(vault: repo, fromAttempts: true)
        await send(m)
        #expect(m.state.error == .retry && m.state.step == .current && m.state.fromAttempts)
        #expect(m.state.current.isEmpty && m.state.pin.isEmpty && m.state.confirm.isEmpty && m.state.password.isEmpty)
        #expect(!"\(m.state)".contains("59173048"))
    }

    /// VAULT-MESSAGING §11.14.9 step 4: a wrong PIN is shown as it is, with the current PIN cleared and the new one kept
    /// (only confirmed again); a wrong password clears the password (and the keypad's confirmation, typed with it).
    @Test func aRefusalClearsTheEntryThatWasWrong() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.badPin, code: "bad_pin")
        let m = ChangePinViewModel(vault: repo, fromAttempts: true)
        await send(m)
        #expect(m.state.error == .badPin && m.state.step == .current && m.state.fromAttempts && m.state.check == nil)
        #expect(m.state.current.isEmpty && m.state.pin == "59173048" && m.state.password.isEmpty)
        repo.fail["changePin"] = FakeVaultRepository.failure(.badPassword, code: "bad_password")
        m.setCurrent("40281795")
        m.next()
        #expect(m.state.step == .confirm)
        m.setConfirm("59173048")
        m.setPassword("pw")
        m.next()
        await m.settle()
        #expect(m.state.error == .badPassword && m.state.step == .confirm)
        #expect(m.state.current == "40281795" && m.state.pin == "59173048" && m.state.confirm.isEmpty && m.state.password.isEmpty)
    }

    /// VAULT-MESSAGING §11.14.9 "A lost answer": no answer is no failure. While the change is decided the checking text
    /// is shown and the new PIN kept; the decision arrives: applied is the usual success, and is not shown again.
    @Test func noAnswerIsCheckedNotFailed() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.pin, .checking)
        let m = ChangePinViewModel(vault: repo)
        await send(m)
        #expect(m.state.check == .checking && m.state.error == nil && !m.state.done)
        #expect(m.state.pin == "59173048" && m.state.current.isEmpty && m.state.password.isEmpty)
        #expect(repo.changeCheckAwaited, "the shell's notice leaves the decision to this screen")
        repo.changeCheck = ChangeCheck(.pin, .unreachable)
        await m.settle()
        #expect(await until { m.state.check == .unreachable })
        repo.changeCheck = ChangeCheck(.pin, .applied)
        #expect(await until { m.state.done })
        #expect(repo.changeCheck == nil && repo.calls.contains("acknowledgeChangeCheck") && !repo.changeCheckAwaited)
    }

    /// Decided not applied: "not changed"; the new PIN is kept, so after the current PIN it is only confirmed and sent.
    @Test func notAppliedKeepsTheNewPinForTheNextAttempt() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.pin, .checking)
        let m = ChangePinViewModel(vault: repo)
        await send(m)
        repo.changeCheck = ChangeCheck(.pin, .notApplied)
        #expect(await until { m.state.check == .notApplied })
        atNew(m)
        #expect(m.state.step == .confirm)
        m.setConfirm("59173048")
        m.setPassword("pw")
        m.next()
        await m.settle()
        #expect(m.state.done && repo.lastPin == "59173048" && repo.calls.filter { $0 == "changePin" }.count == 2)
    }

    /// The check ended without a decision (VAULT-MESSAGING 0.45.0 §11.14.9 step 3), later or at once: said so, and
    /// nothing is kept for a retry that would send the PIN again.
    @Test func anEndedCheckKeepsNothingForARetry() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.pin, .checking)
        let later = ChangePinViewModel(vault: repo)
        await send(later)
        repo.changeCheck = ChangeCheck(.pin, .ended)
        #expect(await until { later.state.check == .ended })
        #expect(later.state.pin.isEmpty && later.state.current.isEmpty && later.state.error == nil)
        repo.fail["changePin"] = FakeVaultRepository.failure(.other)
        repo.changeCheck = ChangeCheck(.pin, .ended)
        let atOnce = ChangePinViewModel(vault: repo)
        await send(atOnce)
        #expect(atOnce.state.check == .ended && atOnce.state.pin.isEmpty && atOnce.state.error == nil)
        // "Lock and unlock now": the unlock's two prompts settle the PIN.
        #expect(atOnce.offersLockAndUnlock)
        atOnce.lockAndUnlock()
        await atOnce.settle()
        #expect(repo.calls.contains("lock"))
    }

    /// A PIN change refused while a new phone secret cannot be decided offers the lock and unlock too.
    @Test func anUndecidedRenewOffersALockAndUnlock() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.renewUnconfirmed, code: VaultManager.codeRenewUnconfirmed)
        let m = ChangePinViewModel(vault: repo)
        await send(m)
        #expect(m.state.error == .renewUnconfirmed && m.offersLockAndUnlock)
    }

    /// The change's own call decided it not applied (or `stale_credential`): said so, the new PIN kept.
    @Test func aChangeDecidedNotAppliedAtOnce() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.other, code: VaultManager.codeChangeNotApplied)
        let m = ChangePinViewModel(vault: repo)
        await send(m)
        #expect(m.state.check == .notApplied && m.state.error == nil && m.state.pin == "59173048")
    }

    /// A refusal decided later (the resend's own answer) is shown as it is, with the entry that was wrong cleared; a
    /// decision for the password change is not this screen's.
    @Test func aLaterRefusalIsShownAsItIs() async {
        repo.fail["changePin"] = FakeVaultRepository.failure(.changeUnresolved, code: VaultManager.codeChangeUnresolved)
        repo.changeCheck = ChangeCheck(.pin, .checking)
        let m = ChangePinViewModel(vault: repo)
        await send(m)
        repo.changeCheck = ChangeCheck(.password, .notApplied)
        await m.settle()
        #expect(m.state.check == .checking)
        repo.changeCheck = ChangeCheck(.pin, .refused(.badPin, code: "bad_pin"))
        #expect(await until { m.state.error == .badPin })
        #expect(m.state.check == nil && m.state.current.isEmpty && m.state.pin == "59173048")
    }

    /// A decision reached while the screen was closed is the shell's notice: a screen opened later does not show it, nor
    /// acknowledge it.
    @Test func aDecisionReachedElsewhereIsNotShownHere() async {
        repo.changeCheck = ChangeCheck(.pin, .applied)
        let m = ChangePinViewModel(vault: repo)
        await m.settle()
        #expect(!m.state.done && m.state.check == nil && repo.changeCheck == ChangeCheck(.pin, .applied))
    }

    /// Opening the screen while a change is undecided shows where it stands.
    @Test func theScreenOpensOnAnUndecidedChange() {
        repo.changeCheck = ChangeCheck(.pin, .unreachable)
        #expect(ChangePinViewModel(vault: repo).state.check == .unreachable)
    }

    /// Waits (up to 2 s) until [condition] holds.
    func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
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
