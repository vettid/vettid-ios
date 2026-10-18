import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The vault as the app reaches it for a lock; everything it was asked, in order.
@MainActor
final class ScriptedLockPorts: LockPorts {
    var asked: [String] = []
    var relay = false
    var member: MemberLock = .noAnswer
    var unlocked: Bool? = true
    let relayValidFor: Duration = .seconds(30)
    /// When set, the relay lock waits for it: the vault's answer is on its way.
    var relayGate: TestDeferred<Void>?

    func relayLock() async -> Bool {
        asked.append("relay")
        try? await relayGate?.value()
        return relay
    }

    func memberLock() async -> MemberLock {
        asked.append("member")
        return member
    }

    func unlocked() async -> Bool? {
        asked.append("status")
        return unlocked
    }
}

/// The rules of a pending lock (``LockGuard``), through the three ways the vault is reached. Mirrors vettid-android
/// `LockGuardTest`: each of the first four tests fails when its rule is taken out.
@MainActor
@Suite struct LockGuardTests {
    let clock = VirtualClock()
    let ports = ScriptedLockPorts()
    let store = MemoryLockStore()

    var t0: Date { clock.t0 }

    /// Retries only when a test advances an hour: each test makes its attempts itself.
    func guarded() -> LockGuard {
        let (store, clock) = (store, clock)
        return LockGuard(ports: ports, now: clock.now, sleep: clock.sleep) { attempt in
            LockKeeper(store: store, attempt: attempt, now: clock.now, backoff: { _ in .seconds(3600) }, sleep: clock.sleep)
        }
    }

    /// The member API's answer to a lock request never confirms it.
    @Test func theMemberApisAnswerToALockNeverConfirmsIt() async {
        let g = guarded()
        for answer in [MemberLock.answered(done: false), .answered(done: true), .noAnswer] {
            ports.member = answer
            let attempt = Task { @MainActor in await g.attempt(first: false) }
            await clock.advance(by: 5_000)
            #expect(!(await attempt.value), "\(answer), and the status still says unlocked")
        }
        // The enclave answers "done" whatever became of its lock: only the status decides.
        ports.member = .answered(done: true)
        ports.unlocked = nil
        let unreadable = Task { @MainActor in await g.attempt(first: false) }
        await clock.advance(by: 5_000)
        #expect(!(await unreadable.value), "a status that could not be read confirms nothing")
        ports.unlocked = false
        #expect(await g.attempt(first: false))
        // And through the keeper: pending until the status says so.
        ports.unlocked = true
        let asking = Task { @MainActor in await g.keeper.ask() }
        await clock.advance(by: 5_000)
        #expect(!(await asking.value))
        #expect(g.pending)
        ports.unlocked = false
        await clock.advance(by: 3_600_001)
        #expect(!g.pending)
        #expect(g.keeper.notice == .confirmedLate)
    }

    /// While a lock is pending this phone is locked whatever the status says.
    @Test func whileALockIsPendingThisPhoneIsLockedWhateverTheStatusSays() async {
        let g = guarded()
        #expect(!g.lockedWhatever(unlocked: true), "nothing pending: the status decides")
        #expect(!(await g.keeper.ask()))
        #expect(g.lockedWhatever(unlocked: true), "the status says unlocked: locked here all the same")
        #expect(g.pending)
        #expect(g.lockedWhatever(unlocked: nil), "not readable: locked, and not confirmed")
        #expect(g.pending)
        #expect(g.lockedWhatever(unlocked: false), "it says locked: locked, and now confirmed")
        #expect(!g.pending)
        #expect(store.record == LockRecord(relayLockUntilMs: t0.ms + 40_000))
        #expect(!g.lockedWhatever(unlocked: true))
    }

    /// While a lock is pending nothing is sent to the vault but the lock and a hang-up.
    @Test func whileALockIsPendingNothingIsSentToTheVaultButTheLockAndAHangUp() async {
        let g = guarded()
        #expect(g.admits())
        #expect(!(await g.keeper.ask()))
        #expect(!g.admits(), "an operation on the open vault")
        #expect(g.admits(.lock) && g.admits(.callEnd))
        g.keeper.confirmed()
        #expect(g.admits())
    }

    /// While a lock is pending nothing the vault sends is taken in.
    @Test func whileALockIsPendingNothingTheVaultSendsIsTakenIn() async {
        let g = guarded()
        #expect(g.takesEvents())
        #expect(!(await g.keeper.ask()))
        #expect(!g.takesEvents())
        let clock = clock
        let unlock = Task { @MainActor in await g.keeper.unlocking(opened: { $0 }) { true } }
        await clock.advance(by: 60_000) // the relay lock's validity and margin
        _ = await unlock.value
        #expect(g.takesEvents(), "an unlock later than the lock: open again")
    }

    /// From the moment the lock is asked for, before its hooks and its first attempt, every rule holds.
    @Test func theRulesHoldFromTheMomentTheLockIsAskedFor() async {
        let g = guarded()
        let mine = g.keeper.begin() // VaultManager.lock(), before the hooks
        #expect(ports.asked.isEmpty, "nothing was sent")
        #expect(g.lockedWhatever(unlocked: true), "a refresh that read 'unlocked' a moment ago does not open the app")
        #expect(!g.admits())
        #expect(g.admits(.callEnd), "the hook's own hang-up goes out")
        #expect(!g.takesEvents())
        ports.relay = true
        #expect(await g.keeper.ask(mine))
        #expect(!g.pending)
    }

    /// A lock asked for while an unlock is on its way: the unlock succeeds; the lock is the newer wish and stays pending;
    /// the phase after that unlock is locked, nothing is admitted, and the lock's attempt follows and confirms.
    @Test func anUnlockThatALockOvertookDoesNotOpenThisPhone() async {
        let g = guarded()
        let mayFinish = TestDeferred<Void>()
        let unlock = Task { @MainActor in
            await g.keeper.unlocking(opened: { $0 }) {
                try? await mayFinish.value()
                return true
            }
        }
        await clock.runCurrent()
        let mine = g.keeper.begin() // the member locks while the unlock is on its way
        ports.relay = true
        let answer = TestDeferred<Void>()
        ports.relayGate = answer
        let asking = Task { @MainActor in await g.keeper.ask(mine) }
        await clock.runCurrent()
        #expect(ports.asked.isEmpty, "the lock waits for the unlock")
        mayFinish.complete()
        #expect(await unlock.value, "the unlock itself succeeded")
        // What the vault manager asks before it publishes a phase: the status says unlocked, a lock is pending.
        #expect(g.lockedWhatever(unlocked: true))
        #expect(!g.admits() && !g.takesEvents())
        answer.complete()
        #expect(await asking.value)
        #expect(ports.asked == ["relay"], "the lock went out after the unlock")
        #expect(!g.pending)
    }

    /// The relay lock: by the first attempt alone, recorded before it is sent, forgotten when the vault answers.
    @Test func theRelayLockIsSentOnceAndItsValidityIsOnThePhoneBeforeItGoesOut() async {
        let g = guarded()
        #expect(!(await g.keeper.ask()))
        #expect(ports.asked == ["relay", "member", "status"])
        #expect(store.record.relayLockUntilMs == t0.ms + 40_000, "until its exp and a margin")
        ports.asked = []
        await clock.advance(by: 3_600_001)
        #expect(ports.asked == ["member", "status"], "a retry sends no relay lock")

        ports.relay = true
        ports.asked = []
        #expect(await g.keeper.ask())
        #expect(ports.asked == ["relay"], "the vault's own answer is enough")
        #expect(store.record == LockRecord())
    }

    /// After a 429 the member API is not asked to lock again before its time; the status still is.
    @Test func aRateLimitedMemberApiIsNotAskedAgainBeforeItsTime() async {
        let g = guarded()
        ports.member = .limited(retryAfter: .seconds(120))
        #expect(!(await g.attempt(first: false)))
        #expect(ports.asked == ["member", "status"])
        ports.asked = []
        await clock.advance(by: 119_000)
        #expect(!(await g.attempt(first: false)))
        #expect(ports.asked == ["status"], "no POST, the status read stays")
        ports.unlocked = false
        #expect(await g.attempt(first: false), "and a status that says locked confirms meanwhile")
        ports.unlocked = true
        ports.asked = []
        await clock.advance(by: 1_000)
        // A 429 without a time: a minute.
        ports.member = .limited(retryAfter: .zero)
        #expect(!(await g.attempt(first: false)))
        #expect(ports.asked == ["member", "status"])
        ports.asked = []
        await clock.advance(by: 59_000)
        #expect(!(await g.attempt(first: false)))
        #expect(ports.asked == ["status"])
        await clock.advance(by: 1_000)
        ports.member = .noAnswer
        #expect(!(await g.attempt(first: false)))
        #expect(ports.asked == ["status", "member", "status"])
    }

    /// After an answered request the status may take a moment to follow: read up to three times, a second apart.
    @Test func afterAnAnsweredRequestTheStatusIsGivenAMomentToFollow() async {
        let g = guarded()
        ports.member = .answered(done: true)
        var done = false
        let attempt = Task { @MainActor in
            let ok = await g.attempt(first: false)
            done = true
            return ok
        }
        await clock.advance(by: 1_999)
        #expect(!done && ports.asked == ["member", "status", "status"])
        await clock.advance(by: 1)
        #expect(!(await attempt.value))
        #expect(ports.asked == ["member", "status", "status", "status"], "two seconds in all")
    }
}
