import Foundation
import os
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// The release check before the PIN has a deadline: a check still unanswered then is given up as one that did not answer,
/// so "Checking your vault's software" never stays with no keypad and no way on; "Try again" starts a new check.
extension UnlockViewModelTests {
    /// A deadline that ends at once for the first check and not within the test for the later ones.
    static func firstDeadlineEndsAtOnce() -> @Sendable () async throws -> Void {
        let armed = OSAllocatedUnfairLock(initialState: 0)
        return {
            if armed.withLock({ $0 += 1; return $0 }) > 1 { try await Task.sleep(for: .seconds(60)) }
        }
    }

    /// Until [condition] holds (at most a few hundred turns of the main actor).
    @MainActor
    func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// A check that never answers: given up with "Try again", its call cancelled; the next check that answers shows the
    /// keypad.
    @Test func aReleaseCheckThatNeverAnswersIsGivenUp() async {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        vault.preflightWait = {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
        }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: Self.firstDeadlineEndsAtOnce())
        await until { !vm.state.loading }
        #expect(vm.state.preflightError == .noResponse && vm.state.preflight == nil && !vm.state.approveOffer)
        #expect(!vm.state.pinAllowed, "no keypad on an unchecked release")
        await until { cancelled.withLock { $0 } }
        #expect(cancelled.withLock { $0 }, "the given-up call is cancelled")
        vault.preflightWait = nil
        vm.retryPreflight()
        await vm.settle()
        #expect(vm.state.preflightError == nil && vm.state.preflight != nil && vm.state.pinAllowed)
    }

    /// The answer of a check already given up comes late: it changes nothing (the member is on "Try again").
    @Test func aLateAnswerOfAGivenUpCheckChangesNothing() async {
        let answer = OSAllocatedUnfairLock(initialState: false)
        // Not cancellable: the answer comes after the watchdog, whatever it cancels.
        vault.preflightWait = {
            while !answer.withLock({ $0 }) { await Task.yield() }
        }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: {})
        await until { !vm.state.loading }
        #expect(vm.state.preflightError == .noResponse)
        answer.withLock { $0 = true }
        await vm.settle()
        #expect(vm.state.preflightError == .noResponse && vm.state.preflight == nil && !vm.state.loading)
    }

    /// A phone with no usable `user_guid`: a check given up still offers the erase, as a failed check does.
    @Test func aGivenUpCheckOnAPhoneWithNoUserGuidOffersTheErase() async {
        vault.userGuidUsable = false
        vault.preflightWait = { try await Task.sleep(for: .seconds(60)) }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: Self.firstDeadlineEndsAtOnce())
        await until { !vm.state.loading }
        #expect(vm.state.preflightError == .noResponse && vm.state.keysGone)
    }

    /// A check that answers in time keeps its answer: the deadline's later end changes nothing.
    @Test func aCheckThatAnswersKeepsItsAnswer() async throws {
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick, preflightDeadline: {
            try await Task.sleep(for: .milliseconds(100))
        })
        await vm.settle()
        #expect(vm.state.preflight != nil)
        try await Task.sleep(for: .milliseconds(300))
        await vm.settle()
        #expect(vm.state.preflightError == nil && vm.state.preflight != nil && vm.state.pinAllowed)
        #expect(UnlockViewModel.preflightDeadlineSeconds == 90)
    }

    /// A new check supersedes one under way: the earlier one's late answer changes nothing.
    @Test func aNewCheckSupersedesOneUnderWay() async {
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = OSAllocatedUnfairLock(initialState: false)
        vault.preflightWait = {
            started.withLock { $0 = true }
            while !release.withLock({ $0 }) { await Task.yield() }
        }
        let vm = UnlockViewModel(vault: vault, account: vault, tick: ticker.tick)
        await until { started.withLock { $0 } }
        #expect(started.withLock { $0 }, "the first check is under way")
        vault.preflightWait = nil
        vault.fail["preflight"] = VaultFailure(.enclave)
        vm.retryPreflight()
        await until { !vm.state.loading }
        #expect(vm.state.preflightError == .enclave)
        release.withLock { $0 = true }
        await vm.settle()
        #expect(vm.state.preflightError == .enclave && vm.state.preflight == nil, "the first check's late answer is dropped")
    }
}
