import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// (ANDROID-PLAN 0.1.124 §4 "The owner check's progress"; IOS-PLAN §4.17) "Checking with your vault…" while the vault
/// verifies, Lock vault during it, and the "Check passed" tick. Mirrors vettid-android `OwnerCheckProgressTest`.
@MainActor
@Suite struct OwnerCheckProgressTests {
    let vault = FakeVaultRepository(.unlocked)
    let answer = TestDeferred<Void>()

    init() {
        vault.ownerCheck = OwnerCheckView(state: .held, deadline: Date().addingTimeInterval(-600), failures: 1)
    }

    func vm(_ mode: OwnerCheckMode = .gated) async -> OwnerCheckViewModel {
        let vm = OwnerCheckViewModel(repo: vault, vault: vault, tick: {})
        vm.start(mode)
        await vm.settle()
        return vm
    }

    /// Sends a check that the vault holds until ``answer`` completes, and waits until it is out.
    func sendHeld(_ vm: OwnerCheckViewModel) async {
        let answer = answer
        vault.onCheck = { try? await answer.value() }
        vm.setPin("975310")
        vm.setPassword("pw")
        vm.submit()
        for _ in 0..<200 where !vault.calls.contains("check") { await Task.yield() }
        #expect(vault.calls.contains("check"))
    }

    @Test func checkingWhileTheVaultVerifies() async {
        let vm = await vm()
        await sendHeld(vm)
        let s = vm.state
        #expect(s.checking && !s.entriesAllowed && !s.submitAllowed)
        #expect(s.pin.isEmpty && s.password.isEmpty, "the entries go at the send")
        #expect(vault.lastPin == nil, "still with the vault")
        answer.complete(())
        await vm.settle()
        #expect(vault.lastPin == "975310" && vault.lastPassword == "pw")
        #expect(!vm.state.checking && vm.state.passedTick && !vm.state.passed)
        #expect(!vm.state.entriesAllowed, "no second check while the tick shows")
        vm.tickShown()
        #expect(vm.state.passed)
    }

    @Test func lockVaultDuringTheCheckDropsItsAnswer() async {
        vault.checkResults = [.badPin(checksLeft: 8)]
        let vm = await vm()
        await sendHeld(vm)
        #expect(vm.state.lockOffered, "a gated check offers Lock vault")
        vm.lockVault()
        #expect(!vm.state.checking && vm.state.locking)
        answer.complete(())
        await vm.settle()
        #expect(vault.calls.contains("lock"))
        #expect(vm.state.message == nil && !vm.state.passedTick, "the answer after the lock is dropped")
    }

    @Test func aPassAfterTheLockShowsNoTick() async {
        let vm = await vm()
        await sendHeld(vm)
        vm.lockVault()
        answer.complete(())
        await vm.settle()
        #expect(!vm.state.passedTick && !vm.state.passed)
    }

    /// A lock that fails while the dropped check is still out holds back a second check until that one returns.
    @Test func aFailedLockWaitsForTheDroppedCheck() async {
        vault.fail["lock"] = FakeVaultRepository.failure(.network)
        let vm = await vm()
        await sendHeld(vm)
        vm.lockVault()
        await Task.yield()
        for _ in 0..<200 where vm.state.locking { await Task.yield() }
        #expect(!vm.state.locking && vm.state.awaitingDropped)
        vm.setPin("975310")
        vm.setPassword("pw")
        #expect(!vm.state.submitAllowed, "the first check is still out")
        answer.complete(())
        await vm.settle()
        #expect(!vm.state.awaitingDropped && !vm.state.passedTick)
        vm.setPin("975310")
        vm.setPassword("pw")
        #expect(vm.state.submitAllowed)
    }

    /// Lock vault during the re-read after an unanswered check: that answer is dropped too.
    @Test func lockVaultDuringTheRereadDropsTheAnswer() async {
        vault.checkResults = [.failed(.network, code: nil, estimatedLeft: 5)]
        vault.probeResults = [.open]
        let read = TestDeferred<Void>()
        vault.onProbe = { try? await read.value() }
        let vm = await vm()
        vm.setPin("975310")
        vm.setPassword("pw")
        vm.submit()
        for _ in 0..<200 where !vault.calls.contains("probeVault") { await Task.yield() }
        #expect(vault.calls.contains("probeVault") && vm.state.checking)
        vm.lockVault()
        read.complete(())
        await vm.settle()
        #expect(vault.calls.contains("lock"))
        #expect(vm.state.message == nil && !vm.state.checking && vm.state.watch == .none, "the answer is dropped")
    }

    /// The shell hears the check is out in the change that sends it (no update in between), stays told through the tick,
    /// and hears it is back together with the answer's message.
    @Test func theCheckBeingOutIsToldAtTheSendAndWithTheAnswer() async {
        vault.checkResults = [.badPin(checksLeft: 8)]
        let vm = await vm(.voluntary)
        var told: [(Bool, OwnerCheckMessage?)] = []
        vm.onOut = { out in told.append((out, vm.state.message)) }
        let answer = answer
        vault.onCheck = { try? await answer.value() }
        vm.setPin("975310")
        vm.setPassword("pw")
        vm.submit()
        #expect(told.map(\.0) == [true], "at once, in the send")
        answer.complete(())
        await vm.settle()
        #expect(told.count == 2 && told[1].0 == false && told[1].1 == .badPin(checksLeft: 8))
        // Typing again clears the line, and the shell hears it (no failure carried to a gated check).
        vm.setPin("1")
        #expect(told.count == 3 && told[2].0 == false && told[2].1 == nil)
    }

    @Test func thePassStaysOutThroughTheTick() async {
        let vm = await vm(.voluntary)
        var told: [Bool] = []
        vm.onOut = { told.append($0) }
        await sendHeld(vm)
        answer.complete(())
        await vm.settle()
        #expect(told == [true] && vm.state.passedTick)
        vm.tickShown()
        vm.cancel()
        #expect(told == [true, false])
    }

    /// A failed lock while the dropped check is out keeps "Checking with your vault…" (no silent, disabled form).
    @Test func waitingForTheDroppedCheckSaysChecking() async {
        vault.fail["lock"] = FakeVaultRepository.failure(.network)
        let vm = await vm()
        await sendHeld(vm)
        vm.lockVault()
        var n = 0
        while vm.state.locking, n < 200 {
            await Task.yield()
            n += 1
        }
        #expect(vm.state.awaitingDropped && vm.state.checking && vm.state.lockOffered)
        // Never silent: the lock's failure is said, with Lock vault offered again.
        if case .failed(.network, _)? = vm.state.message {} else {
            Issue.record("the lock's failure: \(String(describing: vm.state.message))")
        }
        answer.complete(())
        await vm.settle()
        #expect(!vm.state.checking)
    }

    /// A lock that fails after the check came back waits for nothing.
    @Test func aFailedLockAfterTheAnswerWaitsForNothing() async {
        vault.checkResults = [.badPin(checksLeft: 8)]
        vault.fail["lock"] = FakeVaultRepository.failure(.network)
        let vm = await vm()
        await sendHeld(vm)
        answer.complete(())
        await vm.settle()
        vm.lockVault()
        await vm.settle()
        #expect(!vm.state.locking && !vm.state.awaitingDropped && !vm.state.checking)
        vm.setPin("975310")
        vm.setPassword("pw")
        #expect(vm.state.submitAllowed)
    }

    /// The gated check that took an asked one's place says what the asked one was answered.
    @Test func aCarriedFailureIsSaid() async {
        let vm = OwnerCheckViewModel(repo: vault, vault: vault, tick: {})
        vm.start(.gated, carried: .badPin(checksLeft: 8))
        await vm.settle()
        #expect(vm.state.message == .badPin(checksLeft: 8))
    }

    @Test func leavingTheScreenDropsTheAnswer() async {
        let vm = await vm(.voluntary)
        await sendHeld(vm)
        vm.cancel()
        answer.complete(())
        await vm.settle()
        #expect(!vm.state.passedTick && !vm.state.passed && !vm.state.busy)
    }

    @Test(arguments: [
        OwnerCheckOutcome.badPin(checksLeft: 8), .badPassword(checksLeft: 7), .backoff(retryAfterSeconds: 0),
        .failed(.other, code: nil),
    ])
    func eachFailureGoesBackToTheForm(_ r: OwnerCheckOutcome) async {
        vault.checkResults = [r]
        let vm = await vm()
        await sendHeld(vm)
        answer.complete(())
        await vm.settle()
        #expect(!vm.state.checking && !vm.state.passedTick && vm.state.message != nil)
    }

    /// A pass that still needs presence recorded keeps today's screen, with no tick.
    @Test func aPassNeedingPresenceShowsNoTick() async {
        vault.presenceUnrecorded = true
        let vm = await vm(.voluntary)
        await sendHeld(vm)
        answer.complete(())
        await vm.settle()
        #expect(vm.state.passedUnrecorded && !vm.state.passedTick)
    }

    @Test func noLockOnceTheTickShows() async {
        let vm = await vm()
        await sendHeld(vm)
        answer.complete(())
        await vm.settle()
        vm.lockVault()
        #expect(!vm.state.locking && !vault.calls.contains("lock"))
    }

    @Test func theTickIsHeldOneSecondOrThreeWithVoiceOver() {
        #expect(passedTickHold(voiceOver: false) == .seconds(1))
        #expect(passedTickHold(voiceOver: true) == .seconds(3))
    }
}
