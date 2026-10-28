import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// (IOS-PLAN §6.6; VAULT-MESSAGING §3.6.5 "Ask only for what is used") The unlock asks for the PIN only while the check is not
/// due, and for the PIN and the password on one screen past the deadline; a wrong PIN sends no check; after a wrong password
/// the app opens and the check screen takes over (``OwnerCheckViewModelTests``). Mirrors vettid-android `UnlockCheckInTest`.
@MainActor
@Suite struct UnlockCheckInTests {
    let vault = FakeVaultRepository(.locked)
    let ticker = ManualTicker()
    let pin = "40281795"

    func vm(_ view: OwnerCheckView?) async -> UnlockViewModel {
        vault.ownerCheck = view
        let vm = UnlockViewModel(vault: vault, account: vault, ownerCheck: vault, tick: ticker.tick)
        await vm.settle()
        return vm
    }

    var held: OwnerCheckView {
        OwnerCheckView(state: .held, deadline: Date().addingTimeInterval(-60), intervalSeconds: 86_400, failures: 1)
    }

    @Test func notDueAsksOnlyForThePin() async {
        let vm = await vm(OwnerCheckView(state: .ok, deadline: Date().addingTimeInterval(3_600)))
        #expect(!vm.state.checkDue)
        vm.setPin(pin)
        #expect(vm.state.submitAllowed)
        vm.submit()
        await vm.settle()
        #expect(vault.calls.contains("unlock") && !vault.calls.contains("unlockWithCheck"))
    }

    /// No saved state (a new install, a transfer, a recovery): the PIN only.
    @Test func withoutSavedStateOnlyThePin() async {
        let vm = await vm(nil)
        #expect(!vm.state.checkDue)
        vm.setPin(pin)
        #expect(vm.state.submitAllowed)
    }

    @Test func pastTheDeadlineAsksForBoth() async {
        let vm = await vm(held)
        #expect(vm.state.checkDue)
        vm.setPin(pin)
        #expect(!vm.state.submitAllowed)
        vm.setPassword("correct horse")
        #expect(vm.state.submitAllowed)
        vm.submit()
        await vm.settle()
        #expect(vault.calls.contains("unlockWithCheck") && vault.lastPassword == "correct horse")
        #expect(vm.state.password.isEmpty && vault.phase == .unlocked)
    }

    /// A wrong PIN ends the unlock (§11.8): no check is sent and no check try is used.
    @Test func aWrongPinSendsNoCheck() async {
        let vm = await vm(held)
        vault.unlockResults = [.badPin(retryAfterSeconds: 0)]
        vault.checkResults = [.passed]
        vm.setPin(pin)
        vm.setPassword("pw")
        vm.submit()
        await vm.settle()
        #expect(vm.state.message == .badPin)
        #expect(!vault.calls.contains("check") && vault.unlockCheckOutcome == nil)
        #expect(vault.takeUnlockPin() == nil)
    }

    /// A wrong password does not keep the unlock screen: the vault is open, held, and the check screen says what happened.
    @Test func aWrongPasswordLeavesTheScreenForTheHeldOne() async {
        let vm = await vm(held)
        vault.checkResults = [.badPassword(checksLeft: 7)]
        vm.setPin(pin)
        vm.setPassword("nope")
        vm.submit()
        await vm.settle()
        #expect(vault.phase == .unlocked && vault.unlockCheckOutcome == .badPassword(checksLeft: 7))
        #expect(vault.takeUnlockPin() == pin)
    }
}
