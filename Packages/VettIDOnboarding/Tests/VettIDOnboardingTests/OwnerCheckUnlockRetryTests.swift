import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// (IOS-PLAN §6.6; VAULT-MESSAGING §3.6.5 "Ask only for what is used") The check screen after an unlock whose check failed on
/// the password: the approved line under the counts, the password only with "Check in", the accepted PIN kept in memory only
/// while the screen is in front; a failure that locks shows the lock text. Mirrors vettid-android `UnlockCheckInTest`.
@MainActor
@Suite struct OwnerCheckUnlockRetryTests {
    let vault = FakeVaultRepository(.locked)
    let ticker = ManualTicker()
    let pin = "975310"

    init() {
        vault.ownerCheck = OwnerCheckView(
            state: .held, deadline: Date().addingTimeInterval(-600), failures: 1, waiting: WaitingCounts(messages: 3)
        )
    }

    /// The unlock with its check, then the held screen opened as the app does.
    func heldScreen(_ outcomes: [OwnerCheckOutcome], unlockPin: String? = nil) async throws -> OwnerCheckViewModel {
        vault.checkResults = outcomes
        _ = try await vault.unlockWithCheck(pin: unlockPin ?? pin, password: "nope")
        let vm = OwnerCheckViewModel(repo: vault, vault: vault, tick: ticker.tick)
        vm.start(.gated)
        await vm.settle()
        return vm
    }

    @Test func aWrongPasswordIsSaidOnTheHeldScreenWhichAsksForThePasswordOnly() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 7)])
        let s = vm.state
        #expect(s.pinKept && s.unlockedWrong == 7 && s.message == nil && !s.locked)
        #expect(s.pin == pin)
        #expect(!s.submitAllowed, "the password first")
        vm.setPassword("correct horse")
        #expect(vm.state.unlockedWrong == 7, "typing keeps the line")
        #expect(vm.state.submitAllowed)
        vm.submit()
        await vm.settle()
        #expect(vault.lastPin == pin && vault.lastPassword == "correct horse")
        #expect(vm.state.passed && vm.state.pin.isEmpty && !vm.state.pinKept)
    }

    @Test func anotherWrongPasswordCountsDownAndKeepsThePin() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 7), .badPassword(checksLeft: 6)])
        vm.setPassword("still no")
        vm.submit()
        await vm.settle()
        let s = vm.state
        #expect(s.pinKept && s.unlockedWrong == 6 && s.pin == pin && s.password.isEmpty && s.message == nil)
    }

    /// A backoff used no try: the vault is open, the countdown shows and "Check in" is off until it ends.
    @Test func aBackoffSaysTheVaultIsOpenAndHoldsCheckInUntilItEnds() async throws {
        let vm = try await heldScreen([.backoff(retryAfterSeconds: 3)])
        #expect(vm.state.pinKept && vm.state.unlockedOpen && vm.state.unlockedWrong == nil)
        #expect(vm.state.waitSeconds == 3)
        vm.setPassword("pw")
        #expect(!vm.state.submitAllowed)
        await ticker.advance(3, vm)
        #expect(vm.state.waitSeconds == 0 && vm.state.submitAllowed)
    }

    /// Leaving the front: the PIN is forgotten, and the same screen asks for both.
    @Test func leavingTheFrontForgetsThePin() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 7)])
        vault.setForeground(false)
        await vm.settle()
        #expect(!vm.state.pinKept && vm.state.pin.isEmpty)
        vm.setPassword("pw")
        #expect(!vm.state.submitAllowed, "the PIN again")
        vault.setForeground(true)
    }

    @Test func theScreensOwnForgetAlsoEndsTheRetry() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 7)])
        vm.forgetSecrets()
        #expect(!vm.state.pinKept && vm.state.pin.isEmpty && vm.state.password.isEmpty)
    }

    /// Out of the front and back while the retry's check is on its way: the PIN does not come back with its answer.
    @Test func aQuickLeaveDuringTheRetryDropsThePin() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 7), .badPassword(checksLeft: 6)])
        let gate = TestHold()
        vault.onCheck = { await gate.wait() }
        vm.setPassword("still no")
        vm.submit()
        while gate.count == 0 { await Task.yield() }
        vault.setForeground(false)
        vault.setForeground(true)
        gate.releaseAll()
        await vm.settle()
        #expect(!vm.state.pinKept && vm.state.pin.isEmpty && vm.state.unlockedWrong == nil)
        #expect(vm.state.message == .badPassword(checksLeft: 6))
    }

    /// The app left the front while the unlock and its check were on their way: no PIN, and the spent try shows as the
    /// ordinary failure (not a line the member did not see happen).
    @Test func leavingWhileTheUnlockRunsKeepsNoPin() async throws {
        vault.setForeground(false)
        let vm = try await heldScreen([.badPassword(checksLeft: 7)])
        vault.setForeground(true)
        #expect(!vm.state.pinKept && vm.state.unlockedWrong == nil)
        #expect(vm.state.message == .badPassword(checksLeft: 7))
    }

    /// The tenth failure: the lock text, set at once (the flag comes without `vault.locking`), no retry, no "unlocked" line;
    /// "Check in" stays, off, and no entry shows.
    @Test func theTenthFailureShowsTheLockTextAndNoRetry() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 0)])
        let s = vm.state
        #expect(s.locked && s.pinKept && s.pin.isEmpty && s.unlockedWrong == nil && !s.unlockedOpen && s.message == nil)
        #expect(!s.entriesAllowed)
        vm.setPassword("pw")
        vm.setPin(pin)
        #expect(!vm.state.submitAllowed)
    }

    /// The tenth failure on a retry: the screen turns to the lock text and drops the PIN and the "unlocked" line; the
    /// button keeps its label, off.
    @Test func aRetryThatLocksTurnsToTheLockText() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 1), .badPassword(checksLeft: 0)])
        #expect(vm.state.unlockedWrong == 1)
        vm.setPassword("nope")
        vault.lockedByOwnerCheck = true // the manager marks it at once
        vm.submit()
        await vm.settle()
        let s = vm.state
        #expect(s.locked && s.pinKept && !s.submitAllowed && s.unlockedWrong == nil && s.message == nil && s.pin.isEmpty)
    }

    /// A retry answered "none left" before the lock flag comes (the vault's count not read): the PIN goes at once.
    @Test func noTriesLeftDropsThePinBeforeTheLockFlag() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 1), .badPassword(checksLeft: 0)])
        vm.setPassword("nope")
        vm.submit()
        await vm.settle()
        #expect(!vault.lockedByOwnerCheck)
        #expect(!vm.state.pinKept && vm.state.pin.isEmpty && vm.state.unlockedWrong == nil)
        #expect(!vm.state.submitAllowed)
    }

    /// A lock that comes while the retry shows ends it (any `vault.locking` reason), as the lock flag says.
    @Test func aLockWhileRetryingEndsTheRetry() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 5)])
        vault.lockedByOwnerCheck = true
        await vm.settle()
        #expect(vm.state.locked && vm.state.pin.isEmpty && vm.state.unlockedWrong == nil)
        // Leaving the front while locked keeps the label; opening again keeps nothing from before.
        vault.setForeground(false)
        await vm.settle()
        #expect(vm.state.pinKept)
        vault.setForeground(true)
        vault.lockedByOwnerCheck = false
        await vm.settle()
        #expect(!vm.state.locked && !vm.state.pinKept)
    }

    /// A failure that is not the vault's verdict on the entries keeps the retry and is said on the same screen.
    @Test func aFailedCheckKeepsTheRetry() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 7), .failed(.network, code: nil)])
        vm.setPassword("pw")
        vm.submit()
        await vm.settle()
        #expect(vm.state.pinKept && vm.state.message == .failed(.network, code: nil) && vm.state.pin == pin)
    }

    /// A refused update after an open whose check failed: the PIN is kept all the same.
    @Test func anUpdateRefusedStillKeepsThePin() async throws {
        vault.unlockResults = [.updateRefused(code: "x")]
        let vm = try await heldScreen([.badPassword(checksLeft: 7)])
        #expect(vm.state.pinKept && vm.state.unlockedWrong == 7)
    }

    /// Only the gated screen retries: a voluntary check shows the answer as before, and the kept PIN is not taken.
    @Test func aVoluntaryCheckKeepsNothing() async throws {
        vault.checkResults = [.badPassword(checksLeft: 7)]
        _ = try await vault.unlockWithCheck(pin: pin, password: "nope")
        let vm = OwnerCheckViewModel(repo: vault, vault: vault, tick: ticker.tick)
        vm.start(.voluntary)
        await vm.settle()
        #expect(!vm.state.pinKept && vm.state.message == .badPassword(checksLeft: 7))
    }

    /// The app leaves the front while the retry's check is on its way and comes back before the answer: the PIN does not
    /// come back with it.
    @Test func leavingWhileTheRetryRunsDoesNotBringThePinBack() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 7), .badPassword(checksLeft: 6)])
        vault.onCheck = { [vault] in
            vault.setForeground(false)
            await Task.yield()
            vault.setForeground(true)
        }
        vm.setPassword("again")
        vm.submit()
        for _ in 0..<5 { await vm.settle() }
        #expect(!vm.state.pinKept && vm.state.pin.isEmpty && vm.state.unlockedWrong == nil)
    }

    /// A lock that fails leaves the screen asking for both, not stuck without a keypad.
    @Test func aFailedLockLeavesTheScreenAskingForBoth() async throws {
        let vm = try await heldScreen([.badPassword(checksLeft: 7)])
        vault.fail["lock"] = VaultFailure(.network)
        vm.lockVault()
        await vm.settle()
        #expect(!vm.state.pinKept && !vm.state.locking && vm.state.pin.isEmpty)
    }
}
