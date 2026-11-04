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

    // MARK: - A task that does not notice the cancel

    /// A wait that ignores cancellation until it is opened (a layer below that does not notice at once); later calls pass.
    final class Stall: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            let first: Bool = lock.withLock {
                calls += 1
                return calls == 1
            }
            guard first else { return }
            await withCheckedContinuation { c in
                let go: Bool = lock.withLock {
                    if open { return true }
                    waiters.append(c)
                    return false
                }
                if go { c.resume() }
            }
        }

        func release() {
            let w: [CheckedContinuation<Void, Never>] = lock.withLock {
                open = true
                defer { waiters.removeAll() }
                return waiters
            }
            for c in w { c.resume() }
        }
    }

    @Test func aLateResultAfterCancelAndANewEnrollmentChangeNothing() async {
        vault.phase = .setup(.newVault)
        let stall = Stall()
        vault.enrollWait = { await stall.wait() }
        let vm = OnboardingViewModel(account: vault, vault: vault, inbox: SetupLinkInbox(), slowAfter: {})
        await vm.settle()
        vm.confirmAccount()
        let pw = "correct horse battery staple"
        func fill() {
            vm.setPin("40281795"); vm.submitPin(); vm.setPinConfirm("40281795"); vm.submitPinConfirm()
            vm.setPassword(pw); vm.setPasswordConfirm(pw); vm.submitPassword()
            vm.submitBackup()
        }
        fill()
        for _ in 0..<200 where !vm.state.slowWait { await Task.yield() }
        vm.cancelRun()
        #expect(vm.state.step == .pinCreate && !vm.state.busy)
        fill() // a second attempt while the first task still runs
        for _ in 0..<500 where vm.state.step != .done { await Task.yield() }
        #expect(vm.state.step == .done)
        stall.release() // the first task comes back late
        await vm.settle()
        #expect(vm.state.step == .done && vm.state.error == nil)
        #expect(vault.calls.filter { $0 == "createCredential" }.count == 1, "the stale task sent nothing more")
    }

    @Test func aLateResultAfterCancelAndANewSendChangeNothing() async {
        vault.phase = .setup(.recovering)
        vault.phoneSecret = true
        let stall = Stall()
        vault.recoveryOpenWait = { await stall.wait() }
        vault.recoveryOpenOutcomes = [RecoveryOpenOutcome("ok", used: 1), RecoveryOpenOutcome("wrong", used: 2)]
        let vm = RecoveryOpenViewModel(move: vault, account: vault, slowAfter: {})
        await vm.settle()
        func send() {
            vm.setPin("975310")
            vm.setPassword("correct horse battery")
            vm.review()
            vm.send()
        }
        send()
        for _ in 0..<200 where !vm.state.slowWait { await Task.yield() }
        vm.cancelSend()
        send()
        for _ in 0..<500 where vm.state.step != .done { await Task.yield() }
        #expect(vm.state.step == .done)
        stall.release()
        await vm.settle()
        #expect(vm.state.step == .done && vm.state.failure == nil, "the late answer of the first send was not applied")
    }

    @Test func aLateResultAfterCancelAndANewUnlockChangeNothing() async {
        let locked = FakeVaultRepository(.locked)
        let stall = Stall()
        locked.unlockWait = { await stall.wait() }
        locked.unlockResults = [.success, .badPin(retryAfterSeconds: 0)]
        let vm = UnlockViewModel(vault: locked, account: locked, slowAfter: {})
        await vm.settle()
        vm.setPin("40281795")
        vm.submit()
        for _ in 0..<200 where !vm.state.slowUnlock { await Task.yield() }
        vm.cancelUnlock()
        #expect(vm.state.pin.isEmpty && !vm.state.busy)
        vm.setPin("40281795")
        vm.submit()
        for _ in 0..<500 where locked.phase != .unlocked { await Task.yield() }
        #expect(locked.phase == .unlocked)
        stall.release()
        await vm.settle()
        #expect(vm.state.message == nil && !vm.state.busy, "the late wrong-PIN answer of the first attempt was not applied")
    }
}
