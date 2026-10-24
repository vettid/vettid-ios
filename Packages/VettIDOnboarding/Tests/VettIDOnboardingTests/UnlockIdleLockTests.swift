import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// Release L (VAULT-MESSAGING §3.6.8): the unlock screen after the vault locked itself. Mirrors vettid-android
/// `UnlockIdleLockTest`.
@MainActor
@Suite struct UnlockIdleLockTests {
    let vault = FakeVaultRepository(.locked)
    let ticker = ManualTicker()

    /// The vault locked itself; the unlock and the check on this screen.
    @Test func anIdleLockIsSaidAndTheCheckAsked() async {
        let vm = UnlockViewModel(vault: vault, account: vault, ownerCheck: vault, tick: ticker.tick)
        await vm.settle()
        #expect(vm.state.idleLocked == nil)
        vault.idleLocked = IdleLocked(afterSeconds: 604_800)
        await vm.settle()
        #expect(vm.state.idleLocked == IdleLocked(afterSeconds: 604_800))
        // The password with the PIN.
        #expect(vm.state.checkDue)
        #expect(!vm.state.lockedByOwnerCheck)
    }

    /// Without the notice (the phone was off): a time past the `idle_lock_at` last read says why.
    @Test func withoutTheNoticeTheTimeLastReadSaysWhy() async {
        let deadline = Date().addingTimeInterval(-8 * 86_400)
        vault.ownerCheck = OwnerCheckView(
            state: .held, deadline: deadline, intervalSeconds: 86_400, failures: 0, hold: true,
            idleLockAt: deadline.addingTimeInterval(604_800)
        )
        // As the manager: the time is the value read before the deadline, not `idle_lock_at` less the deadline.
        vault.idleAfterKnown = 604_800
        let vm = UnlockViewModel(vault: vault, account: vault, ownerCheck: vault, tick: ticker.tick)
        await vm.settle()
        #expect(vm.state.idleLocked == IdleLocked(afterSeconds: 604_800))
    }

    /// The member locked the vault on this phone: `idle_lock_at` passing says nothing.
    @Test func aLockMadeHereIsNotSaidToBeAnIdleLock() async {
        let deadline = Date().addingTimeInterval(-8 * 86_400)
        vault.ownerCheck = OwnerCheckView(
            state: .held, deadline: deadline, intervalSeconds: 86_400, failures: 0, hold: true,
            idleLockAt: deadline.addingTimeInterval(604_800)
        )
        vault.onLockedHere()
        let vm = UnlockViewModel(vault: vault, account: vault, ownerCheck: vault, tick: ticker.tick)
        await vm.settle()
        #expect(vm.state.idleLocked == nil)
    }
}
