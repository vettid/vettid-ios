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

    /// The backoff holds the cancel until it ends, in the view model too; the screen shows its countdown in the PIN block.
    @Test func theBackoffHoldsTheCancel() async {
        let vm = await cancelledWithAWrongPin(wait: 30)
        #expect(vm.state.waitSeconds > 0 && vm.state.showsPin)
        #expect(!vm.state.cancelAllowed(pinTyped: 8), "not during the wait")
        vm.setPin("11112222")
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vault.lastPin != "11112222", "nothing sent during the wait")
        #expect(vm.state.pin.isEmpty, "the refused PIN does not stay in memory")
        await ticker.advance(30, vm)
        #expect(vm.state.waitSeconds == 0 && vm.state.cancelAllowed(pinTyped: 8))
    }

    /// Two taps on the cancel with a correct PIN send one request.
    @Test func twoTapsSendOneCancel() async {
        vault.unlockResults = [.recoveryPending]
        let vm = await vm()
        await submit(vm)
        let before = vault.calls.filter { $0 == "unlock" }.count
        vm.cancelRecoveryAndUnlock()
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "unlock" }.count == before + 1 && vault.phase == .unlocked)
    }

    /// After a cancel answered `device_secret` the keypad shows, but the earlier keys are neither offered nor sent while a
    /// recovery is pending: only its cancel goes (the plain unlock would only be answered `recovery_pending` again).
    @Test func theEarlierKeysWaitForTheRecovery() async {
        vault.earlierSecretOffered = true
        vault.unlockResults = [.recoveryPending, .failed(.deviceSecret, code: "device_secret")]
        let vm = await vm()
        await submit(vm)
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vm.state.recoveryPending && vm.state.keysGone && vm.state.earlierSecret && vm.state.showsPin)
        #expect(!vm.state.earlierSecretOffered)
        let sent = vault.calls.count
        vm.setPin("40281795")
        vm.submitEarlierSecret()
        await vm.settle()
        #expect(vault.calls.count == sent && vm.state.pin.isEmpty)
    }

    /// While a recovery is pending, a plain submit sends nothing: only the member's cancel goes.
    @Test func aSubmitWhileARecoveryIsPendingSendsNothing() async {
        let vm = await cancelledWithAWrongPin()
        vault.lastPin = nil
        vault.lastCancelRecovery = false
        await submit(vm)
        #expect(vault.lastPin == nil && !vault.lastCancelRecovery && vm.state.recoveryPending)
    }

    /// `backoff` on the cancel (no wrong-PIN text) asks for another PIN as `bad_pin` does.
    @Test func aBackoffOnTheCancelAsksForAnotherPin() async {
        vault.unlockResults = [.recoveryPending, .backoff(retryAfterSeconds: 0)]
        let vm = await vm()
        await submit(vm)
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vm.state.cancelPinWrong && vm.state.message != .badPin && vm.state.showsPin && vm.state.pin.isEmpty)
    }

    /// A failure answering the cancel after a wrong PIN: the PIN goes, the keypad stays, another PIN is asked for.
    @Test func aFailedCancelAfterAWrongPinKeepsTheKeypad() async {
        let vm = await cancelledWithAWrongPin()
        vault.unlockResults = [.failed(.network, code: nil)]
        vm.setPin("40281795")
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vm.state.recoveryPending && vm.state.cancelPinWrong && vm.state.pin.isEmpty && vm.state.showsPin)
        #expect(!vm.state.cancelAllowed(pinTyped: 0) && vm.state.cancelAllowed(pinTyped: 8))
    }

    /// The PIN kept from the `recovery_pending` answer is gone (a trip to the background, "Cancel" on a slow answer, a
    /// failure): the cancel is not enabled for an empty PIN, the keypad asks for one, and the cancel sends it.
    @Test func aCancelWhoseKeptPinIsGoneAsksForOne() async {
        for clear in ["background", "failure"] {
            let vault = FakeVaultRepository(.locked)
            vault.unlockResults = clear == "failure" ? [.recoveryPending, .failed(.network, code: nil)] : [.recoveryPending]
            let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick)
            await vm.settle()
            vm.setPin("40281795")
            vm.submit()
            await vm.settle()
            #expect(!vm.state.showsPin && vm.state.cancelAllowed(pinTyped: 0), "the kept PIN goes with the cancel")
            if clear == "background" {
                vm.forgetSecrets()
            } else {
                vm.cancelRecoveryAndUnlock()
                await vm.settle()
            }
            #expect(vm.state.cancelPinNeeded && vm.state.showsPin && !vm.state.cancelAllowed(pinTyped: 0), "\(clear)")
            vm.setPin("40281795")
            vm.cancelRecoveryAndUnlock()
            await vm.settle()
            #expect(vault.lastCancelRecovery && vault.phase == .unlocked, "\(clear)")
        }
    }

    /// The PIN typed for the cancel keeps the keypad up while it is sent (no jump, no lost focus).
    @Test func aTypedCancelPinKeepsTheKeypadUp() async {
        vault.unlockResults = [.recoveryPending]
        let vm = await vm()
        await submit(vm)
        vm.forgetSecrets()
        vm.setPin("40281795")
        #expect(vm.state.cancelPinNeeded && vm.state.showsPin && vm.state.cancelAllowed)
        vm.cancelRecoveryAndUnlock()
        await vm.settle()
        #expect(vault.phase == .unlocked && !vm.state.cancelPinTyped && !vm.state.cancelPinNeeded)
    }

    /// "Cancel" on a slow cancel drops the kept PIN: the keypad asks for one.
    @Test func cancellingASlowCancelAsksForAPin() async {
        vault.unlockResults = [.recoveryPending]
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, slowAfter: {})
        await vm.settle()
        await submit(vm)
        vault.unlockWait = { try await Task.sleep(for: .seconds(60)) }
        vm.cancelRecoveryAndUnlock()
        for _ in 0..<200 where !vm.state.slowUnlock { await Task.yield() }
        vm.cancelUnlock()
        await vm.settle()
        #expect(vm.state.cancelPinNeeded && vm.state.showsPin && !vm.state.cancelAllowed(pinTyped: 0))
    }

    /// During an erase the cancel is never allowed and the keypad is not shown.
    @Test func anEraseHoldsTheCancelAndItsKeypad() async {
        vault.unlockResults = [.recoveryPending]
        let vm = await vm()
        await submit(vm)
        var s = vm.state
        s.erasing = true
        #expect(!s.cancelAllowed(pinTyped: 8))
        s.pin = ""
        #expect(!s.showsPin && !s.cancelAllowed(pinTyped: 8))
    }

    /// A vault past its owner-check deadline, with no phone secret: the cancel waits for the password, as the unlock does,
    /// so the button is never enabled for a cancel the view model would refuse.
    @Test func aDueCheckHoldsTheCancelUntilThePassword() async {
        vault.unlockResults = [.recoveryPending]
        let vm = await vm()
        vm.ownerCheck(due: true, lockedByChecks: false)
        vm.setPassword("the password")
        await submit(vm)
        #expect(vm.state.recoveryPending && vm.state.cancelPasswordNeeded && vm.state.password.isEmpty)
        #expect(!vm.state.cancelAllowed(pinTyped: 8))
        vm.setPassword("the password")
        #expect(vm.state.cancelAllowed(pinTyped: 0))
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
