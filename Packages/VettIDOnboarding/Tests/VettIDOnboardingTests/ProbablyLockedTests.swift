import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The waits between the reads while the vault is probably locked: recorded, at once; [stopAfter] waits end the schedule
/// there, as if the screen were still waiting for the next read.
final class ReadWaits: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var stopAfter: Int?

    var gaps: [Duration] { lock.withLock { recorded } }

    func wait(_ d: Duration) throws {
        try lock.withLock {
            if let stop = stopAfter, recorded.count >= stop { throw CancellationError() }
            recorded.append(d)
        }
    }
}

/// (VAULT-MESSAGING 0.73.0–0.73.2 §3.6.5; IOS-PLAN 0.1.49) "Probably locked, checking": the estimate of tries left at 0
/// shows no fields and no check while the vault's state is read again, and an unanswered check above 0 says it may have
/// counted. Mirrors vettid-android `ProbablyLockedTest`.
@MainActor
@Suite struct ProbablyLockedTests {
    let vault = FakeVaultRepository(.unlocked)
    let ticker = ManualTicker()
    let waits = ReadWaits()

    init() {
        vault.ownerCheck = OwnerCheckView(state: .held, deadline: Date().addingTimeInterval(-600), failures: 9)
    }

    func model() -> OwnerCheckViewModel {
        let waits = waits
        return OwnerCheckViewModel(repo: vault, vault: vault, tick: ticker.tick, readWait: { try waits.wait($0) })
    }

    /// The gated check sent with [answer].
    func sendCheck(_ answer: OwnerCheckOutcome, mode: OwnerCheckMode = .gated) async -> OwnerCheckViewModel {
        vault.checkResults = [answer]
        let vm = model()
        vm.start(mode)
        await vm.settle()
        vm.setPin("975310")
        vm.setPassword("nope")
        vm.submit()
        await vm.settle()
        return vm
    }

    var probes: Int { vault.calls.filter { $0 == "probeVault" }.count }

    @Test func anEstimateOfZeroSaysProbablyLockedWithNoFieldsAndNoCheck() async {
        waits.stopAfter = 1
        let vm = await sendCheck(.badPassword(checksLeft: 0, estimated: true))
        let s = vm.state
        #expect(s.watch == .checking)
        #expect(!s.locked, "never shown as locked on an estimate")
        #expect(s.pin.isEmpty && s.password.isEmpty && !s.pinKept && s.message == nil)
        #expect(!s.entriesAllowed && !s.submitAllowed)
        #expect(s.lockOffered)
        #expect(probes == 1, "read at once")
        vm.setPin("975310")
        vm.setPassword("pw")
        vm.submit()
        await vm.settle()
        #expect(vault.calls.filter { $0 == "check" }.count == 1, "no check is sent")
    }

    @Test func anUnansweredCheckWithTheEstimateAtZeroIsTheSame() async {
        waits.stopAfter = 1
        let vm = await sendCheck(.failed(.noResponse, code: nil, estimatedLeft: 0))
        #expect(vm.state.watch == .checking && !vm.state.entriesAllowed)
    }

    @Test func aFreshCountOrAnEstimateAboveZeroIsNotProbablyLocked() async {
        let vm = await sendCheck(.badPassword(checksLeft: 3, estimated: true))
        #expect(vm.state.watch == .none && vm.state.message == .badPassword(checksLeft: 3))
        let vm2 = await sendCheck(.badPin(checksLeft: 0))
        #expect(vm2.state.watch == .none)
        #expect(probes == 0)
    }

    @Test func theReadsRunAtOnceThenAt5s15s1minAnd3min() async {
        let vm = await sendCheck(.badPassword(checksLeft: 0, estimated: true))
        #expect(waits.gaps == [.zero, .seconds(5), .seconds(10), .seconds(45), .seconds(120)])
        #expect(probes == 5)
        #expect(vm.state.watch == .silent)
    }

    @Test func anApiLockedShowsTheLockText() async {
        vault.probeResults = [.noAnswer, .locked]
        let vm = await sendCheck(.badPassword(checksLeft: 0, estimated: true))
        let s = vm.state
        #expect(s.locked && !s.lockCauseUnknown && s.watch == .none)
        #expect(!s.entriesAllowed)
        #expect(probes == 2, "the reads end")
    }

    @Test func aVaultStatusAnswerShowsTheCheckWithTheRealCount() async {
        vault.probeResults = [.open]
        let vm = await sendCheck(.badPassword(checksLeft: 0, estimated: true))
        vault.ownerCheck?.failures = 8
        await vm.settle()
        let s = vm.state
        #expect(s.watch == .none && !s.locked && s.entriesAllowed)
        #expect(s.checksLeft == 2)
        #expect(probes == 1)
    }

    @Test func noAnswersEndInIsntAnsweringAndCheckAgainReadsAgain() async {
        let vm = await sendCheck(.badPassword(checksLeft: 0, estimated: true))
        #expect(vm.state.watch == .silent && vm.state.lockOffered && !vm.state.entriesAllowed)
        vault.probeResults = [.open]
        vm.checkAgain()
        await vm.settle()
        #expect(vm.state.watch == .none)
        #expect(probes == 6)
    }

    @Test func aReconnectOrAForegroundReturnReadsAtOnce() async {
        waits.stopAfter = 1
        let vm = await sendCheck(.badPassword(checksLeft: 0, estimated: true))
        #expect(probes == 1)
        vault.reconnectRelay()
        await vm.settle()
        #expect(probes == 2)
        vault.setForeground(false)
        await vm.settle()
        vault.setForeground(true)
        await vm.settle()
        #expect(probes == 3)
        #expect(vm.state.watch == .checking)
    }

    @Test func noReadWhileNotProbablyLocked() async {
        let vm = await sendCheck(.badPassword(checksLeft: 3))
        vault.reconnectRelay()
        await vm.settle()
        #expect(probes == 0)
    }

    @Test func theReadsRunOneAtATime() async {
        waits.stopAfter = 1
        var first = true
        vault.onProbe = { [vault] in
            guard first else { return }
            first = false
            // A reconnect while the first read is out: its read waits for the first.
            vault.reconnectRelay()
            for _ in 0..<20 { await Task.yield() }
        }
        let vm = await sendCheck(.badPassword(checksLeft: 0, estimated: true))
        #expect(probes == 2)
        #expect(vault.maxConcurrentProbes == 1)
        #expect(vm.state.watch == .checking)
    }

    @Test func anUnansweredCheckAboveZeroSaysAtLeastN() async {
        let vm = await sendCheck(.failed(.noResponse, code: nil, estimatedLeft: 4))
        let s = vm.state
        #expect(s.message == .maybeCounted(atLeast: 4))
        #expect(s.watch == .none && s.entriesAllowed)
        #expect(probes == 1)
    }

    @Test func anUnansweredCheckAboveZeroThatFindsTheVaultLockedHasNoKnownCause() async {
        vault.probeResults = [.locked]
        let vm = await sendCheck(.failed(.noResponse, code: nil, estimatedLeft: 4))
        let s = vm.state
        #expect(s.locked && s.lockCauseUnknown)
        #expect(s.message == nil)
    }

    @Test func anUnansweredCheckAboveZeroThatGetsAStatusAnswerKeepsTheFailure() async {
        vault.probeResults = [.open]
        let vm = await sendCheck(.failed(.noResponse, code: nil, estimatedLeft: 4))
        #expect(vm.state.message == .failed(.noResponse, code: nil))
    }

    @Test func thePasswordIsClearedBeforeTheReread() async {
        var seen: String?
        let box = ModelBox()
        vault.onProbe = { seen = box.vm?.state.password }
        vault.checkResults = [.failed(.noResponse, code: nil, estimatedLeft: 4)]
        let vm = model()
        box.vm = vm
        vm.start(.gated)
        vm.setPin("975310")
        vm.setPassword("nope")
        vm.submit()
        await vm.settle()
        #expect(seen == "")
    }

    @Test func lockVaultStopsTheReads() async {
        let box = ModelBox()
        vault.onProbe = { box.vm?.lockVault() }
        vault.checkResults = [.badPassword(checksLeft: 0, estimated: true)]
        let vm = model()
        box.vm = vm
        vm.start(.gated)
        vm.setPin("975310")
        vm.setPassword("nope")
        vm.submit()
        await vm.settle()
        #expect(probes == 1)
        #expect(vault.calls.contains("lock"))
    }

    @Test func aFailedLockLetsTheReadsGoOn() async {
        waits.stopAfter = 1
        let vm = await sendCheck(.badPassword(checksLeft: 0, estimated: true))
        vault.fail["lock"] = VaultFailure(.network)
        waits.stopAfter = nil
        vm.lockVault()
        await vm.settle()
        #expect(!vm.state.locking)
        #expect(probes == 6, "the schedule ran again")
        #expect(vm.state.watch == .silent)
    }

    @Test func cancelStopsTheReads() async {
        let box = ModelBox()
        vault.onProbe = { box.vm?.cancel() }
        vault.checkResults = [.badPassword(checksLeft: 0, estimated: true)]
        let vm = model()
        box.vm = vm
        vm.start(.voluntary)
        vm.setPin("975310")
        vm.setPassword("nope")
        vm.submit()
        await vm.settle()
        #expect(probes == 1)
        #expect(vm.state.watch == .none)
    }

    @Test func lockVaultAndCancelStayOfferedWhileTheReadsRun() {
        var s = OwnerCheckScreenState(mode: .voluntary)
        #expect(!s.lockOffered && !s.cancelBesideLock)
        s.watch = .checking
        #expect(s.lockOffered && s.cancelBesideLock)
        s.mode = .gated
        #expect(s.lockOffered && !s.cancelBesideLock, "a gated check is never left")
        s.watch = .silent
        #expect(s.lockOffered)
    }

    @Test func theUnlockPathFollowsUpAnUnansweredCheck() async throws {
        vault.phase = .locked
        vault.checkResults = [.failed(.noResponse, code: nil, estimatedLeft: 3)]
        _ = try await vault.unlockWithCheck(pin: "975310", password: "nope")
        let vm = model()
        vm.start(.gated)
        await vm.settle()
        #expect(vm.state.message == .maybeCounted(atLeast: 3))
        #expect(probes == 1)
    }

    @Test func theUnlockPathWithTheEstimateAtZeroIsProbablyLocked() async throws {
        vault.phase = .locked
        waits.stopAfter = 1
        vault.checkResults = [.badPassword(checksLeft: 0, estimated: true)]
        _ = try await vault.unlockWithCheck(pin: "975310", password: "nope")
        #expect(!vault.lockedByOwnerCheck, "an estimate never marks the lock")
        let vm = model()
        vm.start(.gated)
        await vm.settle()
        #expect(vm.state.watch == .checking && !vm.state.pinKept && vm.state.pin.isEmpty)
    }

    /// (VAULT-MESSAGING 0.73.1 §3.6.5) The kept PIN survives a check the vault did not answer, unless the tries are then
    /// estimated at 0.
    @Test func keptPinAcrossUnansweredChecks() {
        #expect(OwnerCheckViewModel.keepsPin(.failed(.noResponse, code: nil, estimatedLeft: 2)))
        #expect(OwnerCheckViewModel.keepsPin(.failed(.network, code: nil)))
        #expect(!OwnerCheckViewModel.keepsPin(.failed(.noResponse, code: nil, estimatedLeft: 0)))
        #expect(!OwnerCheckViewModel.keepsPin(.badPassword(checksLeft: 0, estimated: true)))
        #expect(!OwnerCheckViewModel.keepsPin(.failed(.vaultUnavailable, code: VaultManager.codeVaultDeleting)))
    }
}

/// The model under test, for a hook that runs while a read is out.
@MainActor
final class ModelBox {
    var vm: OwnerCheckViewModel?
}
