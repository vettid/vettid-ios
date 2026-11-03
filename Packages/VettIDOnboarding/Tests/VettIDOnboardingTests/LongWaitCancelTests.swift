import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The enrollment and the recovery open that wait long for the vault: after the delay the screen says it may be starting and
/// offers to stop waiting; stopping drops what was typed and leaves the rest to the next start (as the unlock's wait does).
@MainActor
@Suite struct LongWaitCancelTests {
    let vault = FakeVaultRepository()

    @Test func aLongEnrollmentCanBeCancelled() async {
        vault.phase = .setup(.newVault)
        vault.enrollWait = { try await Task.sleep(for: .seconds(60)) }
        let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox(), slowAfter: {})
        await vm.settle()
        vm.confirmAccount()
        let pw = "correct horse battery staple"
        vm.setPin("40281795"); vm.submitPin(); vm.setPinConfirm("40281795"); vm.submitPinConfirm()
        vm.setPassword(pw); vm.setPasswordConfirm(pw); vm.submitPassword()
        vm.submitBackup()
        for _ in 0..<200 where !vm.state.slowWait { await Task.yield() }
        #expect(vm.state.step == .progress && vm.state.busy && vm.state.slowWait)
        vm.cancelRun()
        await vm.settle()
        #expect(!vm.state.busy && !vm.state.slowWait && vm.state.error == nil)
        #expect(vm.state.pin.isEmpty && vm.state.password.isEmpty && vm.state.pinConfirm.isEmpty)
        #expect(vm.state.step == .pinCreate && vm.state.progress.isEmpty)
    }

    @Test func aLongRecoveryOpenCanBeCancelled() async {
        vault.phase = .setup(.recovering)
        vault.phoneSecret = true
        vault.recoveryOpenWait = { try await Task.sleep(for: .seconds(60)) }
        let vm = RecoveryOpenViewModel(move: vault, account: vault, slowAfter: {})
        await vm.settle()
        vm.setPin("975310")
        vm.setPassword("correct horse battery")
        vm.review()
        vm.send()
        for _ in 0..<200 where !vm.state.slowWait { await Task.yield() }
        #expect(vm.state.step == .sending && vm.state.slowWait)
        vm.cancelSend()
        await vm.settle()
        #expect(vm.state.step == .enter && !vm.state.slowWait && vm.state.failure == nil)
        #expect(vm.state.pin.isEmpty && vm.state.password.isEmpty)
        #expect(vault.calls.contains("forgetPairingPin"))
    }

    @Test func aRecoveryOpenTheVaultAlreadyTookGoesToTheFinishAfterCancel() async {
        vault.phase = .setup(.recovering)
        vault.phoneSecret = true
        vault.recoveryOpenWait = { try await Task.sleep(for: .seconds(60)) }
        let vm = RecoveryOpenViewModel(move: vault, account: vault, slowAfter: {})
        await vm.settle()
        vm.setPin("975310")
        vm.setPassword("correct horse battery")
        vm.review()
        vm.send()
        for _ in 0..<200 where !vm.state.slowWait { await Task.yield() }
        vault.recoveryOpenedValue = true
        vm.cancelSend()
        await vm.settle()
        #expect(vm.state.step == .finish)
    }
}
