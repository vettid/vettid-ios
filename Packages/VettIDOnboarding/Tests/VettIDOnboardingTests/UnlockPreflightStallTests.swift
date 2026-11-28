import Foundation
import os
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The release check before the PIN has a watchdog: a check with no sign of progress for a while is given up as one that did
/// not answer, so "Checking your vault's software" never stays with no keypad and no way on. A `release_starting` answer
/// while the routed release starts is progress: it restarts the watchdog, so a release that is starting is waited for.
extension UnlockViewModelTests {
    /// A check that never answers: given up, with "Try again"; the next check that answers shows the keypad.
    @Test func aReleaseCheckThatNeverAnswersIsGivenUp() async {
        vault.preflightWait = { _ in try await Task.sleep(for: .seconds(60)) }
        // The first check's watchdog ends at once; the retry's does not end within the test.
        let armed = OSAllocatedUnfairLock(initialState: 0)
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightStall: {
            if armed.withLock({ $0 += 1; return $0 }) > 1 { try await Task.sleep(for: .seconds(60)) }
        })
        for _ in 0..<200 where vm.state.loading { await Task.yield() }
        #expect(!vm.state.loading && vm.state.preflightError == .noResponse && vm.state.preflight == nil)
        #expect(!vm.state.pinAllowed, "no keypad on an unchecked release")
        vault.preflightWait = nil
        vm.retryPreflight()
        await vm.settle()
        #expect(vm.state.preflightError == nil && vm.state.preflight != nil && vm.state.pinAllowed)
    }

    /// The answer of a check already given up comes late: it changes nothing (the member is on "Try again").
    @Test func aLateAnswerOfAGivenUpCheckChangesNothing() async {
        let answer = OSAllocatedUnfairLock(initialState: false)
        // Not cancellable: the answer comes after the watchdog, whatever it cancels.
        vault.preflightWait = { _ in
            while !answer.withLock({ $0 }) { await Task.yield() }
        }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightStall: {})
        for _ in 0..<200 where vm.state.loading { await Task.yield() }
        #expect(vm.state.preflightError == .noResponse)
        answer.withLock { $0 = true }
        await vm.settle()
        #expect(vm.state.preflightError == .noResponse && vm.state.preflight == nil && !vm.state.loading)
    }

    /// A release that starts: each `release_starting` restarts the watchdog, and the check goes on.
    @Test func aStartingReleaseRestartsTheWatchdog() async {
        let armed = OSAllocatedUnfairLock(initialState: 0)
        let started = OSAllocatedUnfairLock(initialState: false)
        vault.preflightWait = { onStarting in
            onStarting?(5)
            started.withLock { $0 = true }
            try await Task.sleep(for: .seconds(60))
        }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightStall: {
            armed.withLock { $0 += 1 }
            try await Task.sleep(for: .seconds(60))
        })
        for _ in 0..<500 where armed.withLock({ $0 }) < 2 { await Task.yield() }
        #expect(started.withLock { $0 })
        #expect(armed.withLock { $0 } == 2, "armed at the start, then again at release_starting")
        #expect(vm.state.loading && vm.state.preflightError == nil, "still checking")
    }

    /// A check that answers in time keeps its answer: the watchdog's later end changes nothing.
    @Test func aCheckThatAnswersKeepsItsAnswer() async throws {
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightStall: {
            try await Task.sleep(for: .milliseconds(100))
        })
        await vm.settle()
        #expect(vm.state.preflight != nil)
        try await Task.sleep(for: .milliseconds(300))
        await vm.settle()
        #expect(vm.state.preflightError == nil && vm.state.preflight != nil && vm.state.pinAllowed)
        #expect(UnlockViewModel.preflightStallSeconds == 30)
    }

    /// A new check supersedes one still under way: the earlier one's answer changes nothing.
    @Test func aNewCheckSupersedesOneUnderWay() async {
        let release = OSAllocatedUnfairLock(initialState: false)
        vault.preflightWait = { _ in
            while !release.withLock({ $0 }) { await Task.yield() }
        }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick)
        await Task.yield()
        vault.preflightWait = nil
        vault.fail["preflight"] = VaultFailure(.enclave)
        vm.retryPreflight()
        for _ in 0..<200 where vm.state.loading { await Task.yield() }
        #expect(vm.state.preflightError == .enclave)
        release.withLock { $0 = true }
        await vm.settle()
        #expect(vm.state.preflightError == .enclave && vm.state.preflight == nil, "the first check's late answer is dropped")
    }
}
