import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

extension UnlockViewModelTests {
    /// An unlock that waits long says the vault may be starting and can be cancelled: nothing is said of the outcome, the
    /// typed PIN goes, and the keypad is free again.
    @Test func aLongUnlockCanBeCancelled() async {
        vault.unlockWait = { try await Task.sleep(for: .seconds(60)) }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, slowAfter: {})
        await vm.settle()
        vm.setPin("40281795")
        vm.submit()
        for _ in 0..<200 where !vm.state.slowUnlock { await Task.yield() }
        #expect(vm.state.busy && vm.state.slowUnlock)
        vm.cancelUnlock()
        await vm.settle()
        #expect(!vm.state.busy && !vm.state.slowUnlock && vm.state.message == nil && vm.state.pin.isEmpty)
        #expect(vault.phase == .locked)
    }
}

/// A wrong PIN on "Cancel the recovery and unlock": the vault applies the cancel only after a correct PIN, so the recovery
/// stays pending and its answer carries a wait. The keypad asks for another PIN, which the cancel then sends.
extension UnlockViewModelTests {
    /// Pending, then the cancel's PIN wrong; returns the view model there.
    func cancelledWithAWrongPin(wait: Int64 = 0) async -> UnlockViewModel {
        vault.unlockResults = [.recoveryPending, .badPin(retryAfterSeconds: wait)]
        let vm = await vm()
        await submit(vm)
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        return vm
    }

    @Test func aWrongPinOnTheCancelAsksForAnotherAndTheCancelSendsIt() async {
        let vm = await cancelledWithAWrongPin()
        #expect(vm.state.recoveryPending && vm.state.message == .badPin && vault.lastCancelRecovery)
        #expect(vm.state.showsPin && vm.state.pin.isEmpty)
        #expect(!vm.state.cancelAllowed, "a new PIN first")
        vm.setPin("40281795")
        #expect(vm.state.cancelAllowed)
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vault.lastCancelRecovery && vault.lastPin == "40281795" && vault.phase == .unlocked)
        #expect(!vm.state.recoveryPending && !vm.state.cancelPinWrong)
    }

    /// The keypad's own submit goes with the cancel: the plain unlock would only be answered `recovery_pending` again.
    @Test func theKeypadsSubmitAfterAWrongCancelPinIsTheCancel() async {
        let vm = await cancelledWithAWrongPin()
        await submit(vm)
        #expect(vault.lastCancelRecovery && vault.phase == .unlocked)
    }

    /// The backoff holds the cancel until it ends; the screen shows its countdown in the PIN block.
    @Test func theBackoffHoldsTheCancel() async {
        let vm = await cancelledWithAWrongPin(wait: 30)
        #expect(vm.state.waitSeconds > 0 && vm.state.showsPin)
        #expect(!vm.state.cancelAllowed(pinTyped: 8), "not during the wait")
        await ticker.advance(30, vm)
        #expect(vm.state.waitSeconds == 0 && vm.state.cancelAllowed(pinTyped: 8))
    }

    /// With a phone secret, typing the password clears the wrong-PIN text, not the way to type another PIN.
    @Test func aPhoneSecretsPasswordKeepsTheNewPinAsked() async {
        vault.phoneSecret = true
        vault.unlockResults = [.recoveryPending, .badPin(retryAfterSeconds: 0)]
        let vm = await vm()
        await submit(vm)
        vm.setPassword("the password")
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        vm.setPassword("the password")
        #expect(vm.state.message == nil && vm.state.showsPin && vm.state.cancelPinWrong)
        vm.setPin("40281795")
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vault.lastCancelRecovery && vault.lastCancelCheckPassword == "the password" && vault.phase == .unlocked)
    }
}
