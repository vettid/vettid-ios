import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

@MainActor
@Suite struct UnlockLockAgainTests {
    let vault = FakeVaultRepository(.locked)
    let ticker = ManualTicker()

    func vm() async -> UnlockViewModel {
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick)
        await vm.settle()
        return vm
    }

    /// (Release L, owner decision 2026-10-24) "Lock it now" on "Your vault was opened again" asks for one fresh lock.
    @Test func lockItNowAsksForOneFreshLock() async {
        vault.lockNotice = .openedAgain
        let vm = await vm()
        #expect(vm.state.lock == .openedAgain)
        vm.lockAgain()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "lockAgain" }.count == 1)
        #expect(vm.state.lock.inDoubt == false, "a fresh lock is on its way")
        vm.dismissLockNotice()
    }
}
