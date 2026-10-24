import Foundation
import Testing
import VettIDAltChan
@testable import VettIDData
import VettIDDataTesting

/// The vault as the app reaches it for a lock; everything it was asked, in order.
@MainActor
final class ScriptedLockPorts: LockPorts {
    var asked: [String] = []
    var relay = false
    /// When set, the relay's answer instead of ``relay``.
    var relayAnswer: RelayLock?
    /// What the relay and the member API were asked with: the unlock each named.
    var named: [String?] = []
    var member: MemberLock = .noAnswer
    var unlocked: Bool? = true
    let relayValidFor: Duration = .seconds(30)
    /// When set, the relay lock waits for it: the vault's answer is on its way.
    var relayGate: TestDeferred<Void>?

    func relayLock(unlockID: String?) async -> RelayLock {
        asked.append("relay")
        named.append(unlockID)
        try? await relayGate?.value()
        return relayAnswer ?? (relay ? .locked : .noAnswer)
    }

    func memberLock(unlockID: String?) async -> MemberLock {
        asked.append("member")
        named.append(unlockID)
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
            #expect(await attempt.value == .unconfirmed, "\(answer), and the status still says unlocked")
        }
        // The enclave answers "done" whatever became of its lock: only the status decides.
        ports.member = .answered(done: true)
        ports.unlocked = nil
        let unreadable = Task { @MainActor in await g.attempt(first: false) }
        await clock.advance(by: 5_000)
        #expect(await unreadable.value == .unconfirmed, "a status that could not be read confirms nothing")
        ports.unlocked = false
        #expect(await g.attempt(first: false) == .locked)
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
        #expect(g.admits(.lockStatus), "(release L) the status read of \"Lock it now\"")
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
        #expect(await g.attempt(first: false) == .unconfirmed)
        #expect(ports.asked == ["member", "status"])
        ports.asked = []
        await clock.advance(by: 119_000)
        #expect(await g.attempt(first: false) == .unconfirmed)
        #expect(ports.asked == ["status"], "no POST, the status read stays")
        ports.unlocked = false
        #expect(await g.attempt(first: false) == .locked, "and a status that says locked confirms meanwhile")
        ports.unlocked = true
        ports.asked = []
        await clock.advance(by: 1_000)
        // A 429 without a time: a minute.
        ports.member = .limited(retryAfter: .zero)
        #expect(await g.attempt(first: false) == .unconfirmed)
        #expect(ports.asked == ["member", "status"])
        ports.asked = []
        await clock.advance(by: 59_000)
        #expect(await g.attempt(first: false) == .unconfirmed)
        #expect(ports.asked == ["status"])
        await clock.advance(by: 1_000)
        ports.member = .noAnswer
        #expect(await g.attempt(first: false) == .unconfirmed)
        #expect(ports.asked == ["status", "member", "status"])
    }

    /// After an answered request the status may take a moment to follow: read up to three times, a second apart.
    @Test func afterAnAnsweredRequestTheStatusIsGivenAMomentToFollow() async {
        let g = guarded()
        ports.member = .answered(done: true)
        var done = false
        let attempt = Task { @MainActor in
            let outcome = await g.attempt(first: false)
            done = true
            return outcome
        }
        await clock.advance(by: 1_999)
        #expect(!done && ports.asked == ["member", "status", "status"])
        await clock.advance(by: 1)
        #expect(await attempt.value == .unconfirmed)
        #expect(ports.asked == ["member", "status", "status", "status"], "two seconds in all")
    }

    // MARK: - Release L (VAULT-MESSAGING 0.56.4 §10.2 "Locks", §8.6, §11.5; VAULT-LOCK §3.6, §3.7)

    let id = "0123456789abcdef0123456789abcdef"

    /// A bound lock names its unlock over the relay and through the member API, and leaves no wait before an unlock.
    @Test func aBoundLockNamesItsUnlockAndIsSentOverTheRelayAtEveryAttempt() async {
        let g = guarded()
        #expect(!(await g.keeper.ask(g.keeper.begin(unlockID: id))))
        #expect(ports.asked == ["relay", "member", "status"])
        #expect(ports.named == [id, id])
        #expect(store.record == LockRecord(pendingSinceMs: t0.ms, unlockID: id), "bound: nothing to wait out before an unlock")
        ports.asked = []
        await clock.advance(by: 3_600_001)
        #expect(ports.asked == ["relay", "member", "status"], "a retry sends the relay lock again (a late copy is stale_lock)")
        let sentAt = TestBox<Int64>(-1)
        let clock = clock
        _ = await g.keeper.unlocking(opened: { $0 }) {
            sentAt.value = clock.nowMs
            return true
        }
        #expect(sentAt.value == 3_600_001, "no wait before the unlock")
        #expect(store.record == LockRecord())
    }

    /// The slot's `locked` and `not_running` confirm a bound lock; a `done` without a code still does not.
    @Test func aBoundLocksSlotCodesConfirmIt() async {
        let g = guarded()
        for code in [Slot.codeLocked, Slot.codeNotRunning] {
            ports.asked = []
            ports.member = .answered(done: true, code: code)
            #expect(await g.attempt(first: false, unlockID: id) == .locked, "\(code)")
            #expect(ports.asked == ["relay", "member"], "the code decides, no status read")
        }
        ports.member = .answered(done: true)
        let plain = Task { @MainActor in await g.attempt(first: false, unlockID: id) }
        await clock.advance(by: 5_000)
        #expect(await plain.value == .unconfirmed, "a done from a release before L proves nothing")
        ports.member = .answered(done: false, code: Slot.codeLocked)
        let refused = Task { @MainActor in await g.attempt(first: false, unlockID: id) }
        await clock.advance(by: 5_000)
        #expect(await refused.value == .unconfirmed, "a code beside anything but done is not read")
    }

    /// Without the unlock's name (a vault before L, or a phone that does not hold the value, VAULT-LOCK Q3) the lock is #127's
    /// exactly: the relay once, its wait before the next unlock, the slot's codes not read.
    @Test func withoutTheUnlockIDTheLockIsMadeAsBeforeL() async {
        let g = guarded()
        ports.member = .answered(done: true, code: Slot.codeLocked)
        let asking = Task { @MainActor in await g.keeper.ask(g.keeper.begin(unlockID: nil)) }
        await clock.advance(by: 5_000)
        #expect(!(await asking.value))
        #expect(ports.asked == ["relay", "member", "status", "status", "status"])
        #expect(ports.named == [nil, nil], "nothing named: an unconditional API lock")
        #expect(store.record == LockRecord(pendingSinceMs: t0.ms, relayLockUntilMs: t0.ms + 40_000))
        #expect(g.pending, "the host's code is not taken for a lock as before L")
        // A stale_lock to an unbound lock is not the vault's word on it.
        ports.relayAnswer = .stale
        ports.member = .answered(done: true, code: Slot.codeStale)
        let again = Task { @MainActor in await g.attempt(first: true, unlockID: nil) }
        await clock.advance(by: 5_000)
        #expect(await again.value == .unconfirmed)
        ports.asked = []
        await clock.advance(by: 3_600_001)
        #expect(ports.asked.first == "member", "a retry sends no relay lock")
    }

    /// #127's wait before an unlock stays for a lock made as before L: the relay lock's exp and a margin.
    @Test func anUnlockAfterAnUnboundLockWaitsOutItsRelayLock() async {
        let g = guarded()
        let asking = Task { @MainActor in await g.keeper.ask(g.keeper.begin(unlockID: nil)) }
        await clock.advance(by: 5_000)
        _ = await asking.value
        let sentAt = TestBox<Int64>(-1)
        let clock = clock
        let unlock = Task { @MainActor in
            await g.keeper.unlocking(opened: { $0 }) {
                sentAt.value = clock.nowMs
                return true
            }
        }
        await clock.advance(by: 60_000)
        _ = await unlock.value
        #expect(sentAt.value == 40_000)
    }

    /// `stale_lock` over the relay: the vault was opened again since. The lock is over and not repeated, it is not taken as
    /// locked, the member is told, and this phone stays locked until an unlock here.
    @Test func aStaleLockIsNotTakenAsLocked() async {
        let g = guarded()
        ports.relayAnswer = .stale
        #expect(!(await g.keeper.ask(g.keeper.begin(unlockID: id))), "not locked")
        #expect(ports.asked == ["relay", "status"], "the status is read to say what is true now")
        #expect(g.keeper.notice == .openedAgain)
        #expect(!g.pending)
        #expect(store.record == LockRecord(held: true, deadUnlockID: id), "nothing is tried again; held locked on the phone too")
        ports.asked = []
        await clock.advance(by: 3_600_001)
        #expect(ports.asked.isEmpty, "not repeated")
        // This phone is locked all the same, whatever the status says, also once the notice was read.
        #expect(g.lockedWhatever(unlocked: nil))
        #expect(!g.admits() && !g.takesEvents() && g.keeper.openedAgain)
        g.keeper.dismissConfirmed()
        #expect(g.keeper.notice == .none)
        #expect(g.lockedWhatever(unlocked: nil), "dismissing the notice does not open this phone")
        _ = await g.keeper.unlocking(opened: { $0 }) { true }
        #expect(!g.lockedWhatever(unlocked: true), "an unlock here does")
        #expect(store.record == LockRecord())
        #expect(g.admits() && !g.keeper.openedAgain)
    }

    /// The slot's `stale` does the same; and a stale answer after which the status says locked confirms the lock.
    @Test func aStaleSlotEndsTheLockAndTheStatusSaysWhatIsTrueNow() async {
        let g = guarded()
        ports.member = .answered(done: true, code: Slot.codeStale)
        #expect(await g.attempt(first: false, unlockID: id) == .openedAgain)
        ports.unlocked = false
        #expect(await g.attempt(first: false, unlockID: id) == .locked, "locked since: confirmed")
        ports.unlocked = nil
        #expect(await g.attempt(first: false, unlockID: id) == .openedAgain, "unknown: not known locked")
        ports.relayAnswer = .stale
        ports.unlocked = false
        #expect(await g.keeper.ask(g.keeper.begin(unlockID: id)), "stale, then the status says locked: confirmed")
        #expect(g.keeper.notice == .none)
        #expect(!g.lockedWhatever(unlocked: false))
    }
}

/// A value any task may set, for what a test body reads after an `await`.
final class TestBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
