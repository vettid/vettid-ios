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
