import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The vault as the keeper reaches it: each attempt recorded with its time, answered from [answers] (false when empty).
@MainActor
final class ScriptedLockVault {
    var attempts: [(at: Int64, first: Bool)] = []
    var answers: [Bool] = []
    var onAttempt: @MainActor () async throws -> Void = {}
    var throwsError = false
    let clock: VirtualClock

    struct Unreachable: Error {}

    init(clock: VirtualClock) { self.clock = clock }

    func tryLock(_ first: Bool) async throws -> Bool {
        attempts.append((clock.nowMs, first))
        try await onAttempt()
        if throwsError { throw Unreachable() }
        return answers.isEmpty ? false : answers.removeFirst()
    }

    var times: [Int64] { attempts.map(\.at) }
}

/// The member's lock failing secure (owner decision 2026-10-12): pending, durably, until the vault is known to be locked;
/// tried again until then; never after a newer unlock. Virtual time, a store in memory and a scripted vault. Mirrors
/// vettid-android `LockKeeperTest`.
@MainActor
@Suite struct LockKeeperTests {
    let clock = VirtualClock()
    let store = MemoryLockStore()
    let vault: ScriptedLockVault

    init() { vault = ScriptedLockVault(clock: clock) }

    var t0: Date { clock.t0 }

    /// Backoff without jitter: 1 s, 2 s, 5 s, 10 s, then 30 s.
    nonisolated static func steps(_ n: Int) -> Duration { .seconds([1, 2, 5, 10].indices.contains(n) ? [1, 2, 5, 10][n] : 30) }

    func keeper(
        _ s: (any LockRecordStore)? = nil,
        attempt: LockAttempt? = nil,
        backoff: @escaping @Sendable (Int) -> Duration = LockKeeperTests.steps,
        onSaveFailed: @escaping @MainActor (any Error) -> Void = { _ in }
    ) -> LockKeeper {
        let v = vault
        return LockKeeper(
            store: s ?? store, attempt: attempt ?? { try await v.tryLock($0) }, now: clock.now, backoff: backoff, sleep: clock.sleep,
            onSaveFailed: onSaveFailed
        )
    }

    @Test func aLockTheVaultAcknowledgesAtOnceIsNeverInDoubt() async {
        let k = keeper()
        vault.answers = [true]
        // The marker is on the phone before anything is sent.
        let s = store
        let t0 = t0
        var markerSeen = false
        vault.onAttempt = { markerSeen = s.record == LockRecord(pendingSinceMs: t0.ms) }
        #expect(await k.ask())
        #expect(markerSeen)
        #expect(k.notice == .none && !k.pending)
        #expect(store.record == LockRecord())
        await clock.advance(by: 120_000)
        #expect(vault.times == [0], "no retry after a confirmed lock")
    }

    @Test func aLockThatCannotBeConfirmedIsPendingAndTriedAgainUntilItIs() async {
        let k = keeper()
        vault.answers = [false, false, false, false, false, false, true]
        #expect(!(await k.ask()), "not confirmed: the caller is told so, the phone is locked all the same")
        #expect(k.pending)
        #expect(k.notice == .unconfirmed(askedAt: t0, attempts: 1))
        #expect(store.record == LockRecord(pendingSinceMs: t0.ms))
        await clock.advance(by: 48_001) // 1 + 2 + 5 + 10 + 30 s: five more failures
        #expect(vault.times == [0, 1_000, 3_000, 8_000, 18_000, 48_000])
        #expect(vault.attempts.map(\.first) == [true, false, false, false, false, false])
        #expect(k.notice == .unconfirmed(askedAt: t0, attempts: 6))
        #expect(store.record == LockRecord(pendingSinceMs: t0.ms), "still on the phone")
        await clock.advance(by: 30_000)
        #expect(k.notice == .confirmedLate, "the member saw the warning: they are told it is over")
        #expect(!k.pending && store.record == LockRecord())
        await clock.advance(by: 300_000)
        #expect(vault.attempts.count == 7)
        k.dismissConfirmed()
        #expect(k.notice == .none)
    }

    @Test func anAttemptThatThrowsIsAnAttemptThatDidNotConfirm() async {
        let k = keeper()
        vault.throwsError = true
        #expect(!(await k.ask()))
        #expect(k.pending)
        vault.throwsError = false
        vault.answers = [true]
        await clock.advance(by: 1_001)
        #expect(k.notice == .confirmedLate)
    }

    /// Process death: a new keeper over the same store. It starts pending, and tries at once.
    @Test func aPendingLockSurvivesTheProcess() async {
        let first = keeper()
        #expect(!(await first.ask()))
        let asked = store.record
        let attemptsBefore = vault.attempts.count

        let later = MemoryLockStore(asked)
        let next = keeper(later)
        #expect(!next.pending)
        next.resume()
        #expect(next.pending, "locked from the start, before anything else")
        // In doubt from the start: it was not confirmed while the process was gone.
        #expect(next.notice == .unconfirmed(askedAt: t0, attempts: 1))
        vault.answers = [true]
        await clock.runCurrent()
        #expect(vault.attempts[attemptsBefore].first == false, "tried at once, as a retry")
        #expect(next.notice == .confirmedLate)
        #expect(later.record == LockRecord())

        // No marker: nothing is pending and nothing is sent.
        let clean = keeper(MemoryLockStore())
        clean.resume()
        await clock.runCurrent()
        #expect(!clean.pending)
    }

    @Test func aNewerUnlockReplacesAPendingLockWhichIsThenNeverSent() async {
        let k = keeper()
        #expect(!(await k.ask()))
        await clock.advance(by: 1_001)
        #expect(vault.attempts.count == 2)
        // The member unlocks: the vault is open again, by their will, later than the lock.
        let opened = await k.unlocking(opened: { $0 }) { true }
        #expect(opened && !k.pending && k.notice == .none)
        #expect(store.record == LockRecord(), "cleared only now that the unlock succeeded")
        await clock.advance(by: 600_000)
        #expect(vault.attempts.count == 2, "no attempt of the older lock, ever")
        let next = keeper()
        next.resume()
        await clock.runCurrent()
        #expect(!next.pending)
    }

    @Test func anUnlockThatFailsLeavesThePendingLockAsItWas() async {
        let k = keeper()
        #expect(!(await k.ask()))
        #expect(!(await k.unlocking(opened: { $0 }) { false })) // a wrong PIN
        #expect(k.pending && store.record == LockRecord(pendingSinceMs: t0.ms))
        vault.answers = [true]
        await clock.advance(by: 1_001)
        #expect(k.notice == .confirmedLate)
    }

    /// The race: a retry that is due while the unlock runs waits for it, and is not made once the vault has opened.
    @Test func aRetryNeverRunsBesideAnUnlockNorAfterOne() async throws {
        let k = keeper()
        #expect(!(await k.ask()))
        let mayFinish = TestDeferred<Void>()
        let unlock = Task { @MainActor in
            await k.unlocking(opened: { $0 }) {
                try? await mayFinish.value()
                return true
            }
        }
        await clock.runCurrent()
        await clock.advance(by: 60_000) // retries fall due while the unlock is in flight
        #expect(vault.attempts.count == 1, "none was made beside the unlock")
        mayFinish.complete()
        #expect(await unlock.value)
        await clock.advance(by: 600_000)
        #expect(vault.attempts.count == 1, "and none after it")
        #expect(!k.pending)
    }

    /// The other order: an attempt in flight finishes before the unlock starts.
    @Test func anUnlockWaitsForALockAttemptInFlight() async {
        let k = keeper()
        let mayFinish = TestDeferred<Void>()
        vault.onAttempt = { try await mayFinish.value() }
        let asking = Task { @MainActor in await k.ask() }
        await clock.runCurrent()
        var unlocked = false
        let unlock = Task { @MainActor in
            await k.unlocking(opened: { $0 }) {
                unlocked = true
                return true
            }
        }
        await clock.runCurrent()
        #expect(!unlocked, "the unlock waits")
        mayFinish.complete()
        #expect(!(await asking.value))
        #expect(await unlock.value)
        #expect(!k.pending)
        await clock.advance(by: 600_000)
        #expect(vault.attempts.count == 1)
    }

    /// The relay lock got no answer, the lock was then confirmed another way. Nothing is pending, and the relay request may
    /// still be waiting for the vault, which collects again at the next unlock: that unlock is not sent before the request
    /// has expired, with a margin.
    @Test func anUnlockWaitsOutAnUnansweredRelayLockAlsoWhenTheLockWasConfirmedAnotherWay() async {
        var k: LockKeeper?
        let clock = clock
        k = keeper(attempt: { _ in
            k?.relayLockSent(validFor: .seconds(30))
            try await clock.sleep(.seconds(10)) // no answer over the relay; then the status says it is locked
            return true
        })
        let keeper = k!
        let asking = Task { @MainActor in await keeper.ask() }
        await clock.advance(by: 10_000)
        #expect(await asking.value)
        #expect(!keeper.pending)
        #expect(store.record == LockRecord(relayLockUntilMs: t0.ms + 40_000), "kept on the phone after the confirmation")
        var sentAt: Int64 = -1
        let unlock = Task { @MainActor in
            await keeper.unlocking(opened: { $0 }) {
                sentAt = clock.nowMs
                return true
            }
        }
        await clock.advance(by: 30_000)
        _ = await unlock.value
        #expect(sentAt == 40_000, "30 s of validity and 10 s of margin after the lock was sent")
        #expect(store.record == LockRecord())
        // Nothing left to wait for.
        let start = clock.nowMs
        _ = await keeper.unlocking(opened: { $0 }) { true }
        #expect(clock.nowMs == start)
    }

    /// The time is on the phone, so a new process waits too; and an answered relay lock is not waited for.
    @Test func theWaitForAnUnansweredRelayLockSurvivesTheProcessAndEndsWithItsAnswer() async {
        let k = keeper()
        k.relayLockSent(validFor: .seconds(30))
        await clock.advance(by: 5_000)
        let next = keeper() // a keeper that knows only what is on the phone
        var sentAt: Int64 = -1
        let clock = clock
        let unlock = Task { @MainActor in
            await next.unlocking(opened: { $0 }) {
                sentAt = clock.nowMs
                return false // a wrong PIN
            }
        }
        await clock.advance(by: 35_000)
        _ = await unlock.value
        #expect(sentAt == 40_000)
        // An unlock that failed after the wait does not wait again.
        _ = await next.unlocking(opened: { $0 }) {
            sentAt = clock.nowMs
            return false
        }
        #expect(sentAt == 40_000)

        k.relayLockSent(validFor: .seconds(30))
        k.relayLockAnswered()
        #expect(store.record.relayLockUntilMs == nil)
        _ = await k.unlocking(opened: { $0 }) {
            sentAt = clock.nowMs
            return true
        }
        #expect(sentAt == 40_000, "answered: the vault acted on it, nothing is on its way")
    }

    /// A phone whose clock was set back must not hold an unlock for longer than the longest a relay lock can live.
    @Test func theWaitForARelayLockIsBounded() async {
        store.record = LockRecord(relayLockUntilMs: t0.ms + 2 * 86_400_000)
        let k = keeper()
        var sentAt: Int64 = -1
        let clock = clock
        let unlock = Task { @MainActor in
            await k.unlocking(opened: { $0 }) {
                sentAt = clock.nowMs
                return true
            }
        }
        await clock.advance(by: 120_000)
        _ = await unlock.value
        #expect(sentAt == LockKeeper.settleMax.milliseconds)
    }

    /// While the first try runs nothing has failed, and nothing says it has.
    @Test func nothingIsInDoubtBeforeATryHasFailed() async {
        let k = keeper()
        let clock = clock
        vault.onAttempt = { try await clock.sleep(.seconds(3)) }
        let asking = Task { @MainActor in await k.ask() }
        await clock.advance(by: 1_000)
        #expect(k.pending, "pending all the same: the phone is locked")
        #expect(!k.notice.inDoubt, "one second into a lock that has not failed: no warning")
        await clock.advance(by: 2_001)
        #expect(k.notice.inDoubt, "the first try failed: now the vault may still be open")
        _ = await asking.value

        // A lock that the first try confirms, however long it took, never showed a warning nor "confirmed late".
        let other = keeper(MemoryLockStore())
        vault.onAttempt = {}
        vault.answers = [true]
        #expect(await other.ask())
        #expect(other.notice == .none)
    }

    /// The lock is pending and on the phone from ``LockKeeper/begin()``, which the manager calls before the hooks that run
    /// ahead of the lock. A process that dies in that time starts locked and tries.
    @Test func aLockIsPendingAndOnThePhoneBeforeAnythingElseIsDoneForIt() async {
        let k = keeper()
        let mine = k.begin()
        #expect(k.pending && store.record == LockRecord(pendingSinceMs: t0.ms))
        #expect(vault.attempts.isEmpty, "nothing was sent yet")

        let next = keeper()
        next.resume()
        #expect(next.pending)
        await clock.runCurrent()
        #expect(vault.attempts.count == 1, "the new process tries")

        vault.answers = [true]
        #expect(await k.ask(mine))
        #expect(!k.pending)
    }

    /// A lock asked for while an unlock is on its way is the newer wish: the unlock, succeeding, does not undo it.
    @Test func aLockAskedForWhileAnUnlockIsOnItsWayOutlivesIt() async {
        let k = keeper()
        let mayFinish = TestDeferred<Void>()
        let unlock = Task { @MainActor in
            await k.unlocking(opened: { $0 }) {
                try? await mayFinish.value()
                return true
            }
        }
        await clock.runCurrent()
        vault.answers = [true]
        let asking = Task { @MainActor in await k.ask() }
        await clock.runCurrent()
        #expect(k.pending)
        #expect(vault.attempts.isEmpty, "the attempt waits for the unlock")
        mayFinish.complete()
        #expect(await unlock.value)
        #expect(await asking.value, "the lock was confirmed after the unlock")
        #expect(vault.attempts.count == 1 && !k.pending && store.record == LockRecord())
    }

    /// Every unlock first locks a running vault (VAULT-MESSAGING §11.4): its `vault.locking`, or a status read meanwhile,
    /// is not evidence for a lock asked while that unlock runs, which the unlock then opens again. The lock stays pending
    /// and its attempt follows the unlock. Evidence for a lock asked before the unlock still counts.
    @Test func evidenceDuringAnUnlockDoesNotConfirmALockAskedWhileItRuns() async {
        let k = keeper()
        let mayFinish = TestDeferred<Void>()
        let unlock = Task { @MainActor in
            await k.unlocking(opened: { $0 }) {
                try? await mayFinish.value()
                return true
            }
        }
        await clock.runCurrent()
        vault.answers = [true]
        let asking = Task { @MainActor in await k.ask() }
        await clock.runCurrent()
        k.confirmed() // the unlock's own vault.locking
        #expect(k.pending, "not this lock's evidence")
        mayFinish.complete()
        #expect(await unlock.value)
        #expect(await asking.value && vault.attempts.count == 1, "the lock was sent after the unlock")
        #expect(!k.pending)

        // A lock asked before an unlock that is still on its way: evidence confirms it.
        let other = keeper(MemoryLockStore())
        #expect(!(await other.ask()))
        let held = TestDeferred<Void>()
        let second = Task { @MainActor in
            await other.unlocking(opened: { $0 }) {
                try? await held.value()
                return false
            }
        }
        await clock.runCurrent()
        other.confirmed()
        #expect(!other.pending)
        held.complete()
        _ = await second.value
    }

    /// Evidence awaited across an unlock (a status read whose answer arrives after the unlock ended) does not confirm a
    /// lock asked during that unlock; evidence read after it does.
    @Test func evidenceReadAcrossAnUnlockConfirmsNothing() async {
        let k = keeper()
        let mark = k.evidenceMark // a refresh begins its status read
        let mayFinish = TestDeferred<Void>()
        let unlock = Task { @MainActor in
            await k.unlocking(opened: { $0 }) {
                try? await mayFinish.value()
                return true
            }
        }
        await clock.runCurrent()
        let asking = Task { @MainActor in await k.ask() }
        await clock.runCurrent()
        mayFinish.complete()
        #expect(await unlock.value)
        #expect(!(await asking.value), "the lock was sent after the unlock, and is not confirmed yet")
        k.confirmed(since: mark) // the status read's answer, produced during the unlock
        #expect(k.pending, "evidence from across the unlock confirms nothing")
        k.confirmed(since: k.evidenceMark)
        #expect(!k.pending, "evidence read after it does")
    }

    /// "Try again" starts a try once in ten seconds at most.
    @Test func tryAgainStartsATryOnceInTenSecondsAtMost() async {
        let k = keeper(backoff: { _ in .seconds(3600) })
        #expect(!k.retryNow(), "nothing pending: nothing to try")
        #expect(!(await k.ask()))
        #expect(k.retryNow())
        await clock.runCurrent()
        #expect(vault.attempts.count == 2)
        for _ in 0..<9 {
            await clock.advance(by: 1_000)
            #expect(!k.retryNow())
        }
        await clock.runCurrent()
        #expect(vault.attempts.count == 2, "nine more taps in nine seconds: no more tries")
        await clock.advance(by: 1_000)
        #expect(k.retryNow())
        await clock.runCurrent()
        #expect(vault.attempts.count == 3)
    }

    /// Every try is one `POST /api/vault/lock`, which the member API allows 30 times in 15 minutes per member. Counted
    /// without jitter and with tries that take no time (the worst case).
    @Test func theRetriesStayUnderTheMemberApisLimitForTheLockRoute() async {
        let k = keeper(backoff: LockKeeper.backoffBase)
        #expect(!(await k.ask()))
        await clock.advance(by: 15 * 60_000)
        let first = vault.attempts.count
        #expect(first == 21, "the first 15 minutes")
        await clock.advance(by: 15 * 60_000)
        #expect(vault.attempts.count - first == 15, "every 15 minutes after: one a minute")
        #expect(k.pending)
    }

    @Test func theCallerOfALockMayGoAwayTheLockDoesNot() async {
        let k = keeper()
        let mayFinish = TestDeferred<Void>()
        vault.onAttempt = { try? await mayFinish.value() }
        let caller = Task { @MainActor in await k.ask() }
        await clock.runCurrent()
        caller.cancel() // the screen that asked went away
        #expect(k.pending, "pending from the moment it was asked")
        vault.onAttempt = {}
        mayFinish.complete()
        vault.answers = [false, true]
        await clock.advance(by: 1_001)
        #expect(k.notice == .confirmedLate)
        #expect(store.record == LockRecord())
    }

    @Test func tryAgainAndEvidenceFromElsewhere() async {
        let k = keeper()
        #expect(!(await k.ask()))
        await clock.advance(by: 18_001) // now waiting 30 s between tries
        let n = vault.attempts.count
        k.retryNow() // "Try again", or the network came back
        await clock.runCurrent()
        #expect(vault.attempts.count == n + 1)
        // The vault's own `vault.locking`, or a status that says locked.
        k.confirmed()
        #expect(k.notice == .confirmedLate && store.record == LockRecord())
        await clock.advance(by: 600_000)
        #expect(vault.attempts.count == n + 1)
        // Evidence without a pending lock changes nothing.
        k.dismissConfirmed()
        k.confirmed()
        #expect(k.notice == .none)
    }

    @Test func aPhoneThatNoLongerHoldsTheVaultStopsTrying() async {
        let k = keeper()
        #expect(!(await k.ask()))
        k.abandon() // erased, or the vault deleted
        #expect(!k.pending && k.notice == .none && store.record == LockRecord())
        await clock.advance(by: 600_000)
        #expect(vault.attempts.count == 1)
    }

    @Test func aSecondLockWhileOneIsPendingIsOneLock() async {
        let k = keeper()
        #expect(!(await k.ask()))
        await clock.advance(by: 500)
        #expect(!(await k.ask()))
        await clock.advance(by: 1_001)
        // The first lock's retry (due at 1 s) was replaced by the second's (due at 1.5 s): one sequence, not two.
        #expect(vault.times == [0, 500, 1_500])
        #expect(vault.attempts.map(\.first) == [true, true, false])
        #expect(store.writes.filter { $0.pendingSinceMs != nil }.count == 2)
    }

    @Test func theDefaultBackoffStartsQuicklyThenSettlesAtAMinute() {
        let base: [Double] = [1, 2, 5, 10, 30, 30, 30, 30, 60, 60]
        for (n, want) in base.enumerated() {
            let got = Double(LockKeeper.defaultBackoff(n).milliseconds) / 1000
            #expect(got >= want && got <= want * 1.2, "\(got) for \(want)")
        }
    }

    @Test func aLockWhoseRecordCannotBeSavedIsStillSentAndRetried() async {
        var failures = 0
        let k = keeper(FailingLockStore(), onSaveFailed: { _ in failures += 1 })
        #expect(!(await k.ask()))
        // Pending in this process, sent at once, and reported.
        #expect(k.pending && vault.times == [0] && failures > 0)
        // Tried again on the backoff, as with a record that was saved.
        await clock.advance(by: 1_001)
        #expect(vault.times == [0, 1_000])
        vault.answers = [true]
        await clock.advance(by: 2_001)
        #expect(!k.pending)
    }

    @Test func aRelayLockWhoseRecordCannotBeSavedStillHoldsAnUnlock() async {
        let k = keeper(FailingLockStore())
        k.relayLockSent(validFor: .seconds(30))
        var sentAt: Int64 = -1
        let clock = clock
        let unlock = Task { @MainActor in
            await k.unlocking(opened: { $0 }) {
                sentAt = clock.nowMs
                return true
            }
        }
        await clock.advance(by: 45_000)
        _ = await unlock.value
        #expect(sentAt == 40_000, "kept in memory: 30 s and the margin")
    }

    @Test func abandoningForgetsTheRelayLocksTimeInMemoryToo() async {
        let k = keeper(FailingLockStore())
        k.relayLockSent(validFor: .seconds(30))
        // The phone was erased; a vault enrolled after it unlocks in the same process at once.
        k.abandon()
        var sentAt: Int64 = -1
        let clock = clock
        _ = await k.unlocking(opened: { $0 }) {
            sentAt = clock.nowMs
            return true
        }
        #expect(sentAt == 0)
    }
}
