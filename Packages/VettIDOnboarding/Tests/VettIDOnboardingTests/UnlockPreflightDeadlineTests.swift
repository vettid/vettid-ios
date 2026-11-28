import Foundation
import os
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// A gate a test opens: each ``wait()`` returns once ``open()`` is called (at once after it); a cancelled wait throws.
final class TestGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (open: false, waiters: [CheckedContinuation<Void, Never>]()))

    func wait() async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
        try Task.checkCancellation()
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// The release check before the PIN has a deadline: a check with no sign of progress for a while is given up as one that
/// did not answer, so "Checking your vault's software" never stays with no keypad and no way on; "Try again" starts a new
/// check. A routed release that starts is progress: it restarts the deadline, and the screen says the vault is starting.
extension UnlockViewModelTests {
    /// Deadlines for the checks in order: the first ends when [first] opens, the later ones not within the test.
    static func deadlines(first: TestGate, armed: OSAllocatedUnfairLock<Int> = .init(initialState: 0))
        -> @Sendable () async throws -> Void {
        return {
            if armed.withLock({ $0 += 1; return $0 }) > 1 { try await Task.sleep(for: .seconds(60)) }
            try await first.wait()
        }
    }

    /// Until [condition] holds, polling every 10 ms for at most 10 s (a loaded runner included).
    @MainActor
    func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A check that never answers: given up with "Try again" once its deadline ends, its call cancelled; the next check that
    /// answers shows the keypad.
    @Test func aReleaseCheckThatNeverAnswersIsGivenUp() async {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        vault.preflightWait = { _ in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
        }
        let deadline = TestGate()
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: Self.deadlines(first: deadline))
        // Not settle(): it would wait for the check that never answers.
        await until { vault.calls.contains("preflight") }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.loading, "waits until the deadline")
        deadline.open()
        await until { !vm.state.loading }
        #expect(vm.state.preflightError == .noResponse && vm.state.preflight == nil && !vm.state.checkStarting)
        #expect(!vm.state.pinAllowed, "no keypad on an unchecked release")
        await until { cancelled.withLock { $0 } }
        #expect(cancelled.withLock { $0 }, "the given-up call is cancelled")
        vault.preflightWait = nil
        vm.retryPreflight()
        await vm.settle()
        #expect(vm.state.preflightError == nil && vm.state.preflight != nil && vm.state.pinAllowed)
    }

    /// The answer of a check already given up comes late, a success or a failure: it changes nothing (the member is on
    /// "Try again").
    @Test(arguments: [false, true])
    func aLateAnswerOfAGivenUpCheckChangesNothing(fails: Bool) async {
        let answer = TestGate()
        // Not cancellable: the answer comes after the deadline, whatever it cancels.
        vault.preflightWait = { _ in
            await withCheckedContinuation { c in Task { try? await answer.wait(); c.resume() } }
        }
        if fails { vault.fail["preflight"] = VaultFailure(.enclave) }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: {})
        await until { !vm.state.loading }
        #expect(vm.state.preflightError == .noResponse)
        answer.open()
        await vm.settle()
        #expect(vm.state.preflightError == .noResponse && vm.state.preflight == nil && !vm.state.loading)
    }

    /// An approval ticked on an earlier check's offer stays through a new check of the same offer, but not through one given
    /// up.
    @Test func aGivenUpCheckClearsTheApproval() async {
        vault.preflightInfo = PreflightInfo(
            routed: FakeVaultRepository.release(3), lastNumber: 3, softwareUpdated: false, rollback: false,
            offer: FakeVaultRepository.release(4)
        )
        let second = TestGate()
        let armed = OSAllocatedUnfairLock(initialState: 0)
        // The first check's deadline never ends; the second's when the test opens it.
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: {
            if armed.withLock({ $0 += 1; return $0 }) == 1 { try await Task.sleep(for: .seconds(60)) }
            try await second.wait()
        })
        await vm.settle()
        vm.setApproveOffer(true)
        vault.preflightWait = { _ in try await Task.sleep(for: .seconds(60)) }
        vm.retryPreflight()
        await until { armed.withLock { $0 } == 2 }
        #expect(vm.state.loading && vm.state.approveOffer, "kept while the same offer is read again")
        second.open()
        await until { !vm.state.loading }
        #expect(vm.state.preflightError == .noResponse && !vm.state.approveOffer)
    }

    /// A phone with no usable `user_guid`: a check given up offers no erase (nothing is known of the release) and says only
    /// that the vault cannot be opened from here, as a failed check does.
    @Test func aGivenUpCheckOnAPhoneWithNoUserGuidOffersNoErase() async {
        vault.userGuidUsable = false
        vault.preflightWait = { _ in try await Task.sleep(for: .seconds(60)) }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: {})
        await until { !vm.state.loading }
        #expect(vm.state.preflightError == .noResponse && vm.state.keysGone)
        #expect(!vm.state.eraseOffered && vm.state.stuckWordsOnly)
    }

    /// A routed release that starts: each `release_starting` restarts the deadline and the screen says the vault is
    /// starting; the check's answer ends that.
    @Test func aStartingReleaseRestartsTheDeadlineAndIsShown() async {
        let armed = OSAllocatedUnfairLock(initialState: 0)
        let answer = TestGate()
        vault.preflightWait = { onStarting in
            onStarting?(5)
            try await answer.wait()
        }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: {
            armed.withLock { $0 += 1 }
            try await Task.sleep(for: .seconds(60))
        })
        await until { armed.withLock { $0 } >= 2 }
        #expect(armed.withLock { $0 } == 2, "armed at the start, then again at release_starting")
        #expect(vm.state.loading && vm.state.checkStarting && vm.state.preflightError == nil)
        answer.open()
        await vm.settle()
        #expect(!vm.state.loading && !vm.state.checkStarting && vm.state.preflight != nil && vm.state.pinAllowed)
    }

    /// A check that answers keeps its answer: its deadline's later end changes nothing.
    @Test func aCheckThatAnswersKeepsItsAnswer() async {
        let deadline = TestGate()
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: { try await deadline.wait() })
        await vm.settle()
        #expect(vm.state.preflight != nil)
        deadline.open()
        await vm.settle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.state.preflightError == nil && vm.state.preflight != nil && vm.state.pinAllowed)
        #expect(UnlockViewModel.preflightDeadlineSeconds == 90)
    }

    /// A new check supersedes one under way: the earlier one's call is cancelled and its late answer changes nothing.
    @Test func aNewCheckSupersedesOneUnderWay() async {
        let started = TestGate()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        vault.preflightWait = { _ in
            started.open()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
        }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick)
        try? await started.wait()
        vault.preflightWait = nil
        vault.fail["preflight"] = VaultFailure(.enclave)
        vm.retryPreflight()
        await vm.settle()
        #expect(vm.state.preflightError == .enclave && vm.state.preflight == nil, "the first check's answer is dropped")
        #expect(cancelled.withLock { $0 }, "the first check's call is cancelled")
    }
}
