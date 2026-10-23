import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// "Finish the move" on the new phone (VAULT-MESSAGING §11.14.10 step 4) and its hold (§11.14.9 step 2, 0.45.0). Mirrors
/// vettid-android `FinishMoveHoldTest`, with the in-app keypad handing the PIN over.
@MainActor
@Suite struct FinishMoveViewModelTests {
    let vault = FakeVaultRepository(.setup(.finishing))

    func model() async -> FinishMoveViewModel {
        let vm = FinishMoveViewModel(vault: vault)
        await vm.settle()
        return vm
    }

    var sent: [String] { vault.calls.filter { $0 == "lock" || $0 == "unlock" } }

    @Test func lockAndUnlockWithThePinFinishTheMove() async {
        let vm = await model()
        #expect(vm.state.pinAllowed)
        #expect(vm.finish(pin: "975310"))
        #expect(vm.state.busy && !vm.state.pinAllowed)
        await vm.settle()
        #expect(vm.state.done && !vm.state.busy && vm.state.failure == nil)
        #expect(sent == ["lock", "unlock"] && vault.lastPin == "975310" && vault.phase == .unlocked)
    }

    @Test func aShortPinSendsNothing() async {
        let vm = await model()
        #expect(!vm.finish(pin: "97531"))
        await vm.settle()
        #expect(sent.isEmpty && !vm.state.busy)
    }

    @Test func aSecondTapWhileRunningSendsNothing() async {
        let vm = await model()
        #expect(vm.finish(pin: "975310"))
        #expect(!vm.finish(pin: "975310"))
        await vm.settle()
        #expect(sent == ["lock", "unlock"])
    }

    /// `transfer_incomplete`: "The move to this phone did not finish. Approve it again on your old phone."
    @Test func theMoveThatDidNotFinishIsSaid() async {
        vault.unlockResults = [.failed(.transferIncomplete, code: "transfer_incomplete")]
        let vm = await model()
        vm.finish(pin: "975310")
        await vm.settle()
        #expect(vm.state.failure == .transferIncomplete && !vm.state.done && vm.state.pinAllowed)
    }

    @Test func aWrongPinAndABackoffAreNamed() async {
        vault.unlockResults = [.badPin(retryAfterSeconds: 0), .backoff(retryAfterSeconds: 30), .recoveryPending]
        let vm = await model()
        vm.finish(pin: "111111")
        await vm.settle()
        #expect(vm.state.failure == .badPin)
        vm.finish(pin: "111111")
        await vm.settle()
        #expect(vm.state.failure == .backoff)
        vm.finish(pin: "111111")
        await vm.settle()
        #expect(vm.state.failure == .other && !vm.state.done)
    }

    @Test func aVaultFailureIsShown() async {
        vault.fail["lock"] = FakeVaultRepository.failure(.network)
        let vm = await model()
        vm.finish(pin: "975310")
        await vm.settle()
        #expect(vm.state.failure == .network && !vm.state.busy && !vm.state.done)
    }

    @Test func aNewTryClearsTheEarlierFailure() async {
        vault.unlockResults = [.badPin(retryAfterSeconds: 0)]
        let vm = await model()
        vm.finish(pin: "111111")
        await vm.settle()
        #expect(vm.state.failure == .badPin)
        vm.finish(pin: "975310")
        #expect(vm.state.failure == nil)
        await vm.settle()
        #expect(vm.state.done)
    }

    @Test func finishTheMoveIsHeldWhileAChangeIsUnresolved() async {
        vault.finishMoveHold = .changeChecking
        let vm = await model()
        #expect(vm.state.held == .changeChecking && !vm.state.pinAllowed)
        #expect(!vm.finish(pin: "40281795"))
        await vm.settle()
        #expect(sent.isEmpty && !vault.calls.contains("finishMove"), "nothing sent")
        vault.finishMoveHold = nil
        await vm.settle()
        #expect(vm.state.held == nil && vm.state.pinAllowed)
    }

    /// (§11.14.9 step 2; chosen) Which PIN the vault expects is read when the keypad becomes usable: a change sent or decided
    /// while the member types sends nothing ("earlier request" text), and the PIN typed again goes with a fresh reading.
    @Test func aPinTakenBeforeAChangeSendsNothingAndIsAskedAgain() async {
        vault.pinGeneration = 5
        let vm = await model()
        #expect(vm.state.pinAllowed)
        vault.pinGeneration = 6 // a PIN change began while the member typed
        vm.finish(pin: "40281795")
        await vm.settle()
        #expect(vm.state.failure == .credentialUnsettled && !vm.state.done && sent.isEmpty)
        // The next PIN is typed from the reading taken when the first digit goes in.
        vm.pinTypingStarted()
        vm.finish(pin: "13579246")
        await vm.settle()
        #expect(vault.finishMoveTaken == [5, 6] && vm.state.done)
        #expect(sent == ["lock", "unlock"])
    }

    /// A hold that lifts after the change was decided: the reading is taken again once it does.
    @Test func theReadingIsTakenAfterAHoldLifts() async {
        let vm = await model()
        vault.finishMoveHold = .changeChecking
        await vm.settle()
        #expect(vm.state.held == .changeChecking)
        vault.pinGeneration = 9 // the change decided
        vault.finishMoveHold = nil
        await vm.settle()
        vm.finish(pin: "40281795")
        await vm.settle()
        #expect(vault.finishMoveTaken == [9])
    }

    @Test func theStateNamesNoSecret() async {
        let vm = await model()
        vm.finish(pin: "975310")
        #expect(!"\(vm.state)".contains("975310"))
    }
}
