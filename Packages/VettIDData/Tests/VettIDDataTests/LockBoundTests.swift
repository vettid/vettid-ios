import Foundation
import Testing
import VettIDAltChan
@testable import VettIDData
import VettIDCrypto
import VettIDDataTesting
import VettIDKeys
import VettIDKeysTesting
import VettIDVault

/// Release L: the lock bound to its unlock (VAULT-MESSAGING 0.56.4 §10.2 "Locks"; VAULT-LOCK 0.1.4), across a process death
/// (owner decision 2026-10-23, Q4). Mirrors the release L parts of vettid-android `LockKeeperTest`, `LockAgainTest`,
/// `LockNoticesTest` and `LockRecordFileTest`.
@MainActor
@Suite struct LockKeeperBoundTests {
    let clock = VirtualClock()
    let store = MemoryLockStore()
    let vault: ScriptedLockVault
    let id = "0123456789abcdef0123456789abcdef"
    let now = "00112233445566778899aabbccddeeff"
    let old = "ffeeddccbbaa99887766554433221100"

    init() { vault = ScriptedLockVault(clock: clock) }

    var t0: Date { clock.t0 }

    func keeper(_ s: (any LockRecordStore)? = nil, backoff: @escaping @Sendable (Int) -> Duration = LockKeeperTests.steps) -> LockKeeper {
        let v = vault
        return LockKeeper(store: s ?? store, attempt: { try await v.tryLock($0, $1) }, now: clock.now, backoff: backoff, sleep: clock.sleep)
    }

    /// Killed mid-lock: the next start goes on with the same bound lock, and its confirmation clears the record.
    @Test func aBoundLockKilledMidwayIsTriedAgainBoundAtTheNextStart() async {
        let first = keeper()
        let mine = first.begin(unlockID: id)
        #expect(store.record == LockRecord(pendingSinceMs: t0.ms, unlockID: id), "on the phone before anything is sent")
        // The process dies during the first attempt: nothing of `first` runs again.
        let forever = TestDeferred<Void>()
        vault.onAttempt = { try await forever.value() }
        let asking = Task { @MainActor in await first.ask(mine) }
        await clock.runCurrent()
        asking.cancel()
        vault.onAttempt = {}
        let later = MemoryLockStore(store.record)
        let next = keeper(later)
        next.resume()
        #expect(next.pending && next.boundUnlockID == id)
        vault.outcomes = [.locked]
        await clock.runCurrent()
        #expect(vault.bound == [id, id], "the retry names the same unlock")
        #expect(!next.pending)
        #expect(later.record == LockRecord(), "a confirmed lock clears the record")
        #expect(next.boundUnlockID == nil)
    }

    /// A lock that ends because the vault was opened again: not pending, not repeated, the phone held locked.
    @Test func aLockTheVaultSaysWasOverIsNotRetriedAndHoldsThisPhone() async {
        let k = keeper()
        vault.outcomes = [.openedAgain]
        #expect(!(await k.ask(k.begin(unlockID: id))))
        #expect(k.notice == .openedAgain && !k.pending && k.holdsPhone)
        #expect(store.record == LockRecord(held: true, deadUnlockID: id))
        await clock.advance(by: 600_000)
        #expect(vault.attempts.count == 1)
        // Held across a process death: a new process starts with this phone locked, and says so again.
        let laterStore = MemoryLockStore(store.record)
        let later = keeper(laterStore)
        later.resume()
        #expect(!later.pending && later.holdsPhone)
        #expect(later.notice == .openedAgain)
        #expect(laterStore.record.held, "the new process keeps it on the phone")
        // A new lock while held: pending again, and its confirmation ends the hold.
        vault.outcomes = [.locked]
        #expect(await k.ask(k.begin(unlockID: nil)))
        #expect(!k.holdsPhone)
        #expect(vault.bound == [id, nil])
        #expect(!store.record.held)
    }

    /// A lock asked for while an unlock is on its way outlives it, bound to the opening that unlock made, not to the one
    /// before (which would be answered stale_lock and leave the new opening open).
    @Test func aLockAskedDuringAnUnlockIsBoundToTheNewOpening() async {
        let k = keeper()
        let newID = "fedcba9876543210fedcba9876543210"
        vault.outcomes = [.locked]
        _ = await k.unlocking(opened: { $0 }, unlockIDOf: { _ in newID }) {
            let n = k.begin(unlockID: id) // the member locks while the unlock is on its way
            Task { @MainActor in await k.ask(n) }
            return true
        }
        await clock.runCurrent()
        #expect(vault.bound == [newID], "named the new opening")
        #expect(!k.pending)
        // Without a name in the unlock's result: as before L.
        vault.outcomes = [.locked]
        _ = await k.unlocking(opened: { $0 }) {
            let n = k.begin(unlockID: id)
            Task { @MainActor in await k.ask(n) }
            return true
        }
        await clock.runCurrent()
        #expect(vault.bound == [newID, nil])
    }

    /// "Lock it now" (owner decision 2026-10-24): one fresh lock, bound to the opening the vault's status names now; not
    /// confirmed at first, retried as any lock.
    @Test func lockItNowSendsOneBoundLockThatConfirmsOrRetriesLikeAnyLock() async {
        let k = keeper(backoff: { _ in .seconds(1) })
        vault.outcomes = [.openedAgain]
        #expect(!(await k.ask(k.begin(unlockID: old))))
        #expect(k.notice == .openedAgain)
        let fresh = await LockAgain.unlockID { now }
        #expect(!(await k.ask(k.begin(unlockID: fresh))))
        #expect(k.pending && k.holdsPhone, "still held")
        #expect(store.record == LockRecord(pendingSinceMs: t0.ms, unlockID: now, held: true, deadUnlockID: old))
        vault.outcomes = [.locked]
        await clock.advance(by: 1_001)
        #expect(vault.bound == [old, now, now], "one try, then a retry, both named")
        #expect(k.notice == .confirmedLate)
        #expect(!k.holdsPhone, "locked: the hold ends with it")
        #expect(store.record == LockRecord())
    }

    /// The fresh lock names the opening running now or none, never the stale value.
    @Test func theFreshLockNamesTheOpeningRunningNowOrNone() async {
        struct Offline: Error {}
        #expect(await LockAgain.unlockID { now } == now)
        #expect(await LockAgain.unlockID { nil } == nil, "the status names none (a vault before L)")
        #expect(await LockAgain.unlockID { "" } == nil, "not of the form")
        #expect(await LockAgain.unlockID { throw Offline() } == nil, "not readable: unconditional, never the stale value")
    }

    /// Held after "opened again", a status that is not "unlocked" replaces the notice with "locked"; still held.
    @Test func aLaterLockedStatusReplacesOpenedAgain() async {
        let k = keeper(backoff: { _ in .seconds(3600) })
        vault.outcomes = [.openedAgain]
        _ = await k.ask(k.begin(unlockID: old))
        k.confirmed()
        #expect(k.notice == .confirmedLate && k.holdsPhone)
    }

    /// After a restart a held phone that was since confirmed locked says nothing new.
    @Test func heldAndConfirmedSaysNothingNewAfterARestart() async {
        let k = keeper(backoff: { _ in .seconds(3600) })
        vault.outcomes = [.openedAgain]
        _ = await k.ask(k.begin(unlockID: old))
        k.confirmed()
        let next = keeper(MemoryLockStore(store.record))
        next.resume()
        #expect(next.holdsPhone && next.notice == .none)
    }

    /// "Lock it now" is pending, unbound, before the status is read; the read binds it before its first attempt; a read
    /// that names nothing leaves it unbound (as before L).
    @Test func theFreshLockIsPendingBeforeTheReadAndBoundBeforeItsFirstAttempt() async {
        let k = keeper(backoff: { _ in .seconds(3600) })
        vault.outcomes = [.locked]
        let mine = k.begin(unlockID: nil)
        #expect(k.pending && store.record.unlockID == nil, "pending before anything is read")
        k.rebind(mine, to: now)
        #expect(store.record.unlockID == now)
        #expect(await k.ask(mine))
        #expect(vault.bound == [now])
        vault.outcomes = [.locked]
        let two = k.begin(unlockID: nil)
        k.rebind(two, to: nil)
        #expect(await k.ask(two))
        #expect(vault.bound == [now, nil])
        k.rebind(two, to: now)
        #expect(store.record == LockRecord(), "a lock that is no longer pending is not rebound")
    }

    /// "Lock it now" asked while an unlock is on its way: the unlock binds it to the opening it made; a status answer that
    /// arrives later (read before that opening, so naming the one before) does not take its place.
    @Test func aLateStatusAnswerDoesNotRebindALockAskedDuringAnUnlock() async {
        let k = keeper(backoff: { _ in .seconds(3600) })
        let opening = "fedcba9876543210fedcba9876543210"
        var mine = 0
        var mark = 0
        _ = await k.unlocking(opened: { $0 }, unlockIDOf: { _ in opening }) {
            mine = k.begin(unlockID: nil)
            mark = k.evidenceMark
            // The status is answered while the unlock runs, under the opening before: not used.
            k.rebind(mine, to: old, since: mark)
            return true
        }
        #expect(store.record.unlockID == opening, "the unlock named the opening its lock is for")
        // The answer of the status read arrives after the unlock's result.
        k.rebind(mine, to: old, since: mark)
        #expect(store.record.unlockID == opening && k.boundUnlockID == opening)
        vault.outcomes = [.locked]
        #expect(await k.ask(mine))
        #expect(vault.bound == [opening], "the lock names the opening of this phone's own unlock")
    }

    /// A lock that ends as "opened again" leaves its name dead: told to the device, kept for the notices, ended by an unlock
    /// here or by abandoning the vault.
    @Test func aLockThatEndsOpenedAgainLeavesItsNameDead() async {
        var told: [String?] = []
        let v = vault
        let k = LockKeeper(
            store: store, attempt: { try await v.tryLock($0, $1) }, now: clock.now, backoff: { _ in .seconds(3600) },
            sleep: clock.sleep, onOpenedAgain: { told.append($0) }
        )
        vault.outcomes = [.openedAgain]
        _ = await k.ask(k.begin(unlockID: old))
        #expect(told == [old] && k.deadUnlockID == old)
        _ = await k.unlocking(opened: { $0 }) { true }
        #expect(k.deadUnlockID == nil && !k.holdsPhone)
        vault.outcomes = [.openedAgain]
        _ = await k.ask(k.begin(unlockID: id))
        #expect(k.deadUnlockID == id)
        k.abandon()
        #expect(k.deadUnlockID == nil)
    }

    /// The dead name is kept with the hold: a new process still drops the dead opening's notice, and an unlock ends both.
    @Test func theDeadNameSurvivesARestartWhileHeld() async {
        let k = keeper(backoff: { _ in .seconds(3600) })
        vault.outcomes = [.openedAgain]
        _ = await k.ask(k.begin(unlockID: old))
        #expect(store.record == LockRecord(held: true, deadUnlockID: old))
        let next = keeper(MemoryLockStore(store.record))
        next.resume()
        #expect(next.holdsPhone && next.deadUnlockID == old && next.notice == .openedAgain)
        _ = await next.unlocking(opened: { $0 }) { true }
        #expect(next.deadUnlockID == nil)
    }

    /// An abandoned vault leaves nothing held.
    @Test func abandoningTheVaultEndsTheHold() async {
        let k = keeper(backoff: { _ in .seconds(3600) })
        vault.outcomes = [.openedAgain]
        _ = await k.ask(k.begin(unlockID: old))
        k.abandon()
        #expect(!k.holdsPhone && k.notice == .none && store.record == LockRecord())
    }
}

/// A release L record: the unlock a pending lock is bound to and the held marker are kept; one without them keeps the first
/// version's form.
@MainActor
@Suite struct LockRecordFileBoundTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vettid-lock-tests/\(UUID().uuidString)")
    let keys = InMemoryFileKeyHolder()
    let protected = ProtectedDataFlag(available: true)
    let id = "0123456789abcdef0123456789abcdef"

    func store() -> EncryptedFileStore {
        EncryptedFileStore(url: dir.appendingPathComponent(VaultFiles.lock), purpose: VaultFiles.lock, keys: keys, protectedData: protected)
    }

    func text() throws -> String {
        guard case .found(let b) = try store().lookup() else { return "" }
        return (String(bytes: b, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func aBoundLocksUnlockIsKeptAcrossARestart() throws {
        try LockRecordFile(file: store()).save(LockRecord(pendingSinceMs: 7, unlockID: id))
        #expect(try text() == "2 7 - \(id) 0")
        #expect(LockRecordFile(file: store()).load() == LockRecord(pendingSinceMs: 7, unlockID: id))
        try LockRecordFile(file: store()).save(LockRecord(relayLockUntilMs: 9))
        #expect(try text() == "1 - 9", "the first version's form")
        #expect(LockRecordFile(file: store()).load() == LockRecord(relayLockUntilMs: 9))
    }

    @Test func theDeadNameIsKeptWithTheHoldAndAnOldRecordReadsAsNone() throws {
        let dead = "ffeeddccbbaa99887766554433221100"
        try LockRecordFile(file: store()).save(LockRecord(held: true, deadUnlockID: dead))
        #expect(try text() == "2 - - - 1 \(dead)")
        #expect(LockRecordFile(file: store()).load() == LockRecord(held: true, deadUnlockID: dead))
        try store().save(Array("2 - - - 1".utf8))
        #expect(LockRecordFile(file: store()).load() == LockRecord(held: true))
        #expect(throws: LockRecordFile.NotSaved.self) { try LockRecordFile(file: store()).save(LockRecord(held: true, deadUnlockID: "x")) }
    }

    @Test func theHeldMarkerIsKeptAcrossARestart() throws {
        try LockRecordFile(file: store()).save(LockRecord(relayLockUntilMs: 9, held: true))
        #expect(try text() == "2 - 9 - 1")
        #expect(LockRecordFile(file: store()).load() == LockRecord(relayLockUntilMs: 9, held: true))
        // Held, and since confirmed locked.
        try LockRecordFile(file: store()).save(LockRecord(held: true, heldConfirmed: true))
        #expect(try text() == "2 - - - 2")
        #expect(LockRecordFile(file: store()).load() == LockRecord(held: true, heldConfirmed: true))
    }

    /// A bound record that is not of the form says a lock is pending (fail secure); one with a bad unlock is not saved.
    @Test func aMalformedBoundRecordSaysALockIsPending() throws {
        for text in ["2 7 - xyz 0", "2 - - \(String(repeating: "A", count: 32)) 0", "2 7 - - 3", "2 7 - -", "3 7 - - 0"] {
            try store().save(Array(text.utf8))
            let file = LockRecordFile(file: store(), now: { Date(timeIntervalSince1970: 0.011) })
            #expect(file.load() == LockRecord(pendingSinceMs: 11), "\(text)")
        }
        let bad = LockRecord(pendingSinceMs: 1, unlockID: "nope")
        #expect(throws: LockRecordFile.NotSaved.self) { try LockRecordFile(file: store()).save(bad) }
    }
}

/// A `vault.locking` that names the unlock it ends.
@MainActor
@Suite struct LockNoticesBoundTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000.120)
    let a = String(repeating: "a", count: 32)
    let b = String(repeating: "b", count: 32)

    func named(_ ts: Date, _ id: String?, type: String = "vault.locking") -> VaultMessage {
        let body = id.map { #"{"unlock_id":"\#($0)"}"# } ?? "{}"
        return VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: ts, body: Array(body.utf8)))
    }

    @Test func aNamedNoticeIsJudgedByItsNameWhenThisPhoneHoldsTheCurrentOne() {
        var current: String? = b
        let n = LockNotices(opened: t0)
        n.current = { current }
        #expect(n.stale(named(t0.addingTimeInterval(60), a)), "another opening's lock, however late it says it is")
        #expect(!n.stale(named(t0.addingTimeInterval(-1), b)), "this opening's lock, even with an earlier ts")
        // A notice without a name (a release before L) and a name of another form: by the time, as before L.
        #expect(n.stale(named(t0, nil)))
        #expect(!n.stale(named(t0.addingTimeInterval(0.001), nil)))
        #expect(!n.stale(named(t0.addingTimeInterval(0.001), "")))
        // No current name (a new process before its first status read): by the time.
        current = nil
        #expect(!n.stale(named(t0.addingTimeInterval(60), a)))
        #expect(n.stale(named(t0.addingTimeInterval(-1), b)))
    }

    /// The opening a lock was bound to when the vault said it was over is dead: its late notice is dropped, whether or not this
    /// phone holds a current name, and whatever its time says; a newer name or none is judged as before.
    @Test func aNoticeNamingTheDeadOpeningIsDropped() {
        var current: String?
        let n = LockNotices(opened: t0)
        n.current = { current }
        n.dead = { a }
        #expect(n.stale(named(t0.addingTimeInterval(60), a)), "dead, though later than the last unlock and unjudged by a name")
        current = b
        #expect(n.stale(named(t0.addingTimeInterval(60), a)))
        #expect(!n.stale(named(t0.addingTimeInterval(60), b)), "the newer opening's notice stands")
        current = nil
        #expect(!n.stale(named(t0.addingTimeInterval(60), nil)), "without a name: by the time, as before")
    }

    @Test func onlyANoticeNamingTheBoundUnlockConfirmsABoundLock() {
        let n = LockNotices(opened: t0)
        n.current = { b }
        #expect(n.confirms(named(t0.addingTimeInterval(-1), b), bound: b))
        #expect(!n.confirms(named(t0.addingTimeInterval(60), a), bound: b), "another opening's lock says nothing of this one")
        // An unbound lock, or a notice without a name: from after the last unlock here, as before L.
        #expect(n.confirms(named(t0.addingTimeInterval(1), a), bound: nil))
        #expect(!n.confirms(named(t0, nil), bound: b))
        #expect(n.confirms(named(t0.addingTimeInterval(1), nil), bound: b))
        #expect(!n.confirms(named(t0.addingTimeInterval(1), nil, type: "vault.held"), bound: nil))
    }
}

/// The return to the foreground retries a pending lock, but not over an attempt that runs or just began, and without using up
/// the member's "Try again".
@MainActor
@Suite struct LockForegroundRetryTests {
    let clock = VirtualClock()
    let store = MemoryLockStore()
    let vault: ScriptedLockVault

    init() { vault = ScriptedLockVault(clock: clock) }

    func keeper(_ s: (any LockRecordStore)? = nil) -> LockKeeper {
        let v = vault
        return LockKeeper(
            store: s ?? store, attempt: { try await v.tryLock($0, $1) }, now: clock.now, backoff: { _ in .seconds(3600) },
            sleep: clock.sleep
        )
    }

    @Test func theForegroundDoesNotRaceAnAttemptThatJustBeganAndKeepsTryAgain() async {
        let k = keeper()
        _ = await k.ask(k.begin())
        #expect(vault.attempts.count == 1)
        await clock.advance(by: 1_000)
        #expect(!k.retryOnForeground(), "an attempt began a second ago")
        #expect(k.retryNow(), "the member's Try again is still theirs")
        await clock.runCurrent()
        #expect(vault.attempts.count == 2)
        // Long after, the foreground tries; it does not use up Try again.
        await clock.advance(by: 60_000)
        #expect(k.retryOnForeground())
        await clock.runCurrent()
        #expect(vault.attempts.count == 3)
        #expect(!k.retryOnForeground(), "just tried")
        #expect(k.retryNow(), "Try again within 10 s of the foreground's try works")
        await clock.runCurrent()
        #expect(vault.attempts.count == 4)
    }

    @Test func theForegroundOfAProcessStartDoesNotMakeASecondAttempt() async {
        _ = keeper().begin()
        let next = keeper(MemoryLockStore(store.record))
        next.resume()
        #expect(!next.retryOnForeground(), "resume() made the attempt at once")
        await clock.runCurrent()
        #expect(vault.attempts.count == 1)
    }

    @Test func theForegroundDoesNotStartATryWhileOneRuns() async {
        let k = keeper()
        let forever = TestDeferred<Void>()
        vault.onAttempt = { try await forever.value() }
        let asking = Task { @MainActor in await k.ask(k.begin()) }
        await clock.runCurrent()
        await clock.advance(by: 60_000)
        #expect(!k.retryOnForeground(), "an attempt is running")
        asking.cancel()
    }
}
