import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDKeys
import VettIDKeysTesting

/// The member's lock always completes, and nothing that is finished before it can hold it back. Mirrors vettid-android
/// `LockSequenceTest` on virtual time (a hook here runs on the main actor and cannot block a thread, so vettid-android's
/// blocking-hook case has no counterpart).
@MainActor
@Suite struct LockSequenceTests {
    let clock = VirtualClock()
    let budget: Int64 = 300

    final class Seen {
        var locked = false
        var after = 0
    }

    func sequence(_ hooks: [@MainActor () async throws -> Void] = []) -> LockSequence {
        let s = LockSequence(hookBudget: .milliseconds(budget), sleep: clock.sleep)
        for h in hooks { s.addHook(h) }
        return s
    }

    func lock(_ s: LockSequence, _ seen: Seen) async throws {
        try await s.run(lock: { seen.locked = true }, after: { seen.after += 1 })
    }

    @Test func withoutAHookOrWithOneThatHasNothingToDoThereIsNoDelay() async throws {
        let seen = Seen()
        try await lock(sequence(), seen)
        #expect(seen.locked && clock.nowMs == 0)
        seen.locked = false
        let run = Task { @MainActor in try await lock(sequence([{}]), seen) }
        await clock.runCurrent()
        try await run.value
        #expect(seen.locked && clock.nowMs == 0)
        #expect(seen.after == 2)
    }

    @Test func aHookThatNeverFinishesIsGivenTheBudgetAndNoMore() async throws {
        let seen = Seen()
        let forever = TestDeferred<Void>()
        let run = Task { @MainActor in try await lock(sequence([{ try await forever.value() }]), seen) }
        await clock.advance(by: budget - 1)
        #expect(!seen.locked, "the hook still has its time")
        await clock.advance(by: 1)
        try await run.value
        #expect(seen.locked)
    }

    @Test func aHookThatThrowsStopsNeitherTheNextHookNorTheLock() async throws {
        struct Failed: Error {}
        let seen = Seen()
        var second = false
        let run = Task { @MainActor in try await lock(sequence([{ throw Failed() }, { second = true }]), seen) }
        await clock.runCurrent()
        try await run.value
        #expect(second && seen.locked && clock.nowMs == 0)
    }

    @Test func aCallerThatIsCancelledOnlyStopsWaitingTheLockCompletes() async {
        let seen = Seen()
        var hookStarted = false
        let forever = TestDeferred<Void>()
        let s = sequence([{
            hookStarted = true
            try await forever.value()
        }])
        let caller = Task { @MainActor in try await lock(s, seen) }
        await clock.advance(by: 100)
        caller.cancel()
        #expect(!seen.locked, "not yet: the hook still has its time")
        await clock.advance(by: budget)
        _ = try? await caller.value
        #expect(hookStarted && seen.locked && seen.after == 1)
    }

    @Test func aCallerCancelledDuringTheLockItselfDoesNotStopItEither() async {
        let seen = Seen()
        let clock = clock
        let s = sequence()
        let caller = Task { @MainActor in
            try await s.run(lock: {
                try await clock.sleep(.milliseconds(300)) // the vault's answer is on its way
                seen.locked = true
            }, after: { seen.after += 1 })
        }
        await clock.advance(by: 100)
        caller.cancel()
        await clock.advance(by: 300)
        _ = try? await caller.value
        #expect(seen.locked && seen.after == 1)
    }

    @Test func whenTheVaultCannotBeToldThePhoneStillEndsLockedAndTheCallerLearnsWhy() async {
        struct Unreachable: Error {}
        let seen = Seen()
        await #expect(throws: Unreachable.self) {
            try await sequence().run(lock: { throw Unreachable() }, after: { seen.after += 1 })
        }
        #expect(seen.after == 1, "the phone's own state was set to locked")
    }
}

/// A lock the member asked for is kept across a process death. Mirrors vettid-android `LockRecordFileTest` (no older
/// record to migrate on the iPhone).
@MainActor
@Suite struct LockRecordFileTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vettid-lock-tests/\(UUID().uuidString)")
    let keys = InMemoryFileKeyHolder()
    let protected = ProtectedDataFlag(available: true)

    func store() -> EncryptedFileStore {
        EncryptedFileStore(url: dir.appendingPathComponent(VaultFiles.lock), purpose: VaultFiles.lock, keys: keys, protectedData: protected)
    }

    @Test func aLockIsKeptAcrossARestart() throws {
        try LockRecordFile(file: store()).save(LockRecord(pendingSinceMs: 7, relayLockUntilMs: 9))
        #expect(LockRecordFile(file: store()).load() == LockRecord(pendingSinceMs: 7, relayLockUntilMs: 9))
    }

    @Test func aFileThatCannotBeUnderstoodSaysALockIsPending() throws {
        try store().save(Array("garbage".utf8))
        #expect(LockRecordFile(file: store(), now: { Date(timeIntervalSince1970: 0.011) }).load() == LockRecord(pendingSinceMs: 11))
        try store().save(Array("1 12 x\n".utf8))
        #expect(LockRecordFile(file: store(), now: { Date(timeIntervalSince1970: 0.011) }).load() == LockRecord(pendingSinceMs: 11))
    }

    @Test func theFirstSaveMarksTheFileInUseOnce() throws {
        var inUse = false
        var marks = 0
        let f = LockRecordFile(file: store(), inUse: { inUse }, onFirstSave: {
            marks += 1
            inUse = true
        })
        try f.save(LockRecord(pendingSinceMs: 5))
        try f.save(LockRecord())
        #expect(marks == 1)
        #expect(f.load() == LockRecord())
    }

    @Test func aMissingFileOnceInUseSaysALockIsPending() {
        let f = LockRecordFile(file: store(), inUse: { true }, now: { Date(timeIntervalSince1970: 0.013) })
        #expect(f.load() == LockRecord(pendingSinceMs: 13))
    }

    @Test func aFreshInstallHasNoLock() {
        #expect(LockRecordFile(file: store(), inUse: { false }).load() == LockRecord())
    }

    /// iPhone: while protected data is unavailable a file that is not found cannot be told missing: a lock is pending
    /// (IOS-PLAN §6.3, "Missing is decided only like this").
    @Test func aLockedIPhoneSaysALockIsPending() {
        protected.set(false)
        #expect(LockRecordFile(file: store(), now: { Date(timeIntervalSince1970: 0.021) }).load() == LockRecord(pendingSinceMs: 21))
        protected.set(true)
        #expect(LockRecordFile(file: store()).load() == LockRecord())
    }
}

/// A `vault.locking` from before the last unlock is stale. Mirrors vettid-android `LockNoticesTest`.
@MainActor
@Suite struct LockNoticesTests {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000.120)
    let notices = LockNotices()

    @Test func everyNoticeCountsBeforeTheFirstUnlock() {
        #expect(!notices.stale(type: "vault.locking", ts: t0))
    }

    @Test func aNoticeFromBeforeTheUnlockIsStale() {
        notices.opened(at: t0)
        #expect(notices.stale(type: "vault.locking", ts: t0.addingTimeInterval(-5)))
        // The lock an unlock of a running vault makes comes just before its result, or in the same millisecond.
        #expect(notices.stale(type: "vault.locking", ts: t0.addingTimeInterval(-0.680)))
        #expect(notices.stale(type: "vault.locking", ts: t0))
    }

    @Test func aLaterLockStillLocks() {
        notices.opened(at: t0)
        #expect(!notices.stale(type: "vault.locking", ts: t0.addingTimeInterval(0.001)))
        #expect(!notices.stale(type: "vault.locking", ts: t0.addingTimeInterval(54)))
    }

    /// The last unlock's time is kept on the phone, so a new process still knows it; only a later notice is evidence.
    @Test func aNewProcessKnowsTheLastUnlockAndOnlyALaterNoticeIsEvidenceForALock() {
        let restarted = LockNotices(opened: t0)
        let old = t0.addingTimeInterval(-3600)
        #expect(restarted.stale(type: "vault.locking", ts: old))
        #expect(!restarted.sinceLastOpened(type: "vault.locking", ts: old))
        let later = t0.addingTimeInterval(1)
        #expect(!restarted.stale(type: "vault.locking", ts: later))
        #expect(restarted.sinceLastOpened(type: "vault.locking", ts: later))
        #expect(!restarted.sinceLastOpened(type: "feed.event", ts: later), "only the vault's lock notice")
        // Without a known unlock time a notice cannot be placed: it confirms nothing (the status read does).
        #expect(!notices.sinceLastOpened(type: "vault.locking", ts: later))
    }

    @Test func onlyLockNoticesAreFiltered() {
        notices.opened(at: t0)
        #expect(!notices.stale(type: "vault.held", ts: t0.addingTimeInterval(-5)))
        #expect(!notices.stale(type: "sync.event", ts: t0.addingTimeInterval(-5)))
    }

    @Test func theLatestUnlockCounts() {
        notices.opened(at: t0)
        notices.opened(at: nil) // a result without a ts changes nothing
        notices.opened(at: t0.addingTimeInterval(-60)) // never back
        #expect(notices.stale(type: "vault.locking", ts: t0.addingTimeInterval(-1)))
        notices.opened(at: t0.addingTimeInterval(60))
        #expect(notices.stale(type: "vault.locking", ts: t0.addingTimeInterval(30)))
        #expect(!notices.stale(type: "vault.locking", ts: t0.addingTimeInterval(61)))
    }
}

/// A replaced phone erases itself only on an authenticated signal; every proof wipes once. Mirrors vettid-android
/// `HolderWatchTest`.
@MainActor
@Suite struct HolderWatchTests {
    final class Wipes {
        var count = 0
    }

    let wipes = Wipes()
    let clock = VirtualClock()

    func watch() -> HolderWatch {
        let w = wipes
        return HolderWatch { w.count += 1 }
    }

    func unlinked(_ reason: String?) -> HolderSignal { .vaultEvent(type: "device.unlinked", reason: reason) }

    @Test func deviceUnlinkedTransferredOrReplacedWipes() async {
        for reason in ["transferred", "replaced"] {
            let w = watch()
            #expect(w.onVaultEvent(unlinked(reason)))
            await clock.runCurrent()
        }
        #expect(wipes.count == 2)
    }

    @Test func aSealedUnknownDeviceAtUnlockWipes() async {
        let w = watch()
        #expect(await w.onSealedUnlockResult(.sealedUnlockResult(ok: false, code: "unknown_device")))
        #expect(wipes.count == 1)
    }

    @Test func aTransferApprovalWipesOnTheVaultsUnlinkedNoticeNotOnItsResponse() async throws {
        let w = watch()
        var answered = false
        let clock = clock
        let result = Task { @MainActor in try await w.approveTransfer(wait: .seconds(30), sleep: clock.sleep) { answered = true } }
        await clock.advance(by: 1_000)
        #expect(answered && wipes.count == 0, "the {} alone does not wipe")
        w.onVaultEvent(unlinked("transferred"))
        await clock.runCurrent()
        #expect(try await result.value)
        #expect(wipes.count == 1)
    }

    @Test func aTransferApprovalWithoutTheNoticeDoesNotWipeAndTheLateNoticeDoes() async throws {
        let w = watch()
        let clock = clock
        let result = Task { @MainActor in try await w.approveTransfer(wait: .seconds(30), sleep: clock.sleep) {} }
        await clock.advance(by: 30_000)
        #expect(!(try await result.value) && wipes.count == 0)
        w.onVaultEvent(unlinked("transferred"))
        await clock.runCurrent()
        #expect(wipes.count == 1)
    }

    @Test func twoProofsWipeOnce() async {
        let w = watch()
        w.onVaultEvent(unlinked("transferred"))
        w.onVaultEvent(unlinked("transferred"))
        await clock.runCurrent()
        #expect(wipes.count == 1)
    }

    @Test func theMembersEraseWipesOnce() async {
        let w = watch()
        await w.wipeNow()
        #expect(wipes.count == 1 && w.count == 1)
    }

    @Test func anEraseWhileAProofsWipeRunsWipesOnce() async {
        var running = 0
        let clock = clock
        let wipes = wipes
        let w = HolderWatch {
            running += 1
            try? await clock.sleep(.seconds(1))
            wipes.count += 1
        }
        w.onVaultEvent(unlinked("replaced"))
        await clock.advance(by: 10) // the proof's wipe runs
        let erase = Task { @MainActor in await w.wipeNow() }
        await clock.advance(by: 2_000)
        await erase.value
        #expect(running == 1 && wipes.count == 1)
    }

    @Test func nothingElseWipes() async {
        let w = watch()
        let notProof: [HolderSignal] = [
            unlinked(nil), unlinked("vault_deleted"), unlinked("something_else"),
            .vaultEvent(type: "vault.locking", reason: "recovery"), .vaultEvent(type: "sync.event", reason: nil),
            .sealedUnlockResult(ok: false, code: "bad_pin"), .sealedUnlockResult(ok: true, code: nil),
            .sealedUnlockResult(ok: false, code: "device_secret"),
        ]
        for s in notProof { #expect(!w.onVaultEvent(s), "\(s)") }
        for f in [VaultFailure(.network, code: "token_revoked"), VaultFailure(.other, code: "unreadable_result"),
                  VaultFailure(.unauthorized, code: "unauthorized"), VaultFailure(.servicePaused, code: "vault_unavailable")] {
            #expect(!w.onFailure(f))
        }
        await clock.runCurrent()
        #expect(wipes.count == 0)
    }
}

/// Repeated relay refusals send the open app to the unlock screen, where the PIN asks the enclave. Never a wipe. Mirrors
/// vettid-android `RefusalWatchTest`.
@MainActor
@Suite struct RefusalWatchTests {
    final class Routed {
        var count = 0
    }

    let routed = Routed()

    func watch() -> RefusalWatch {
        let r = routed
        return RefusalWatch { r.count += 1 }
    }

    @Test func repeatedRefusalsSendTheOpenAppToTheUnlockScreenOnce() {
        let w = watch()
        #expect(!w.onRefusals(1, phase: .unlocked))
        #expect(!w.onRefusals(2, phase: .unlocked))
        #expect(routed.count == 0)
        #expect(w.onRefusals(RefusalWatch.threshold, phase: .unlocked))
        #expect(routed.count == 1 && w.suspected)
        // More refusals (or the phase already locked) change nothing.
        #expect(!w.onRefusals(4, phase: .locked))
        #expect(!w.onRefusals(5, phase: .unlocked))
        #expect(routed.count == 1)
    }

    @Test func aWorkingPhoneWithPassingTokenErrorsStaysWhereItIs() {
        let w = watch()
        for n in [1, 2, 0, 1, 2] { w.onRefusals(n, phase: .unlocked) }
        #expect(routed.count == 0 && !w.suspected)
    }

    @Test func onlyTheOpenAppIsSentBack() {
        let w = watch()
        for p in [AppPhase.locked, .starting, .signedOut, .setup(.recovering)] {
            #expect(!w.onRefusals(RefusalWatch.threshold, phase: p), "\(p)")
        }
        #expect(routed.count == 0 && !w.suspected)
    }

    @Test func anySignThatTheVaultKnowsThisPhoneClearsTheSuspicion() {
        let w = watch()
        w.onRefusals(RefusalWatch.threshold, phase: .unlocked)
        #expect(w.suspected)
        w.clear() // a sealed unlock result
        #expect(!w.suspected)
        w.onRefusals(RefusalWatch.threshold, phase: .unlocked)
        #expect(w.suspected)
        w.onRefusals(0, phase: .locked) // a message from the vault
        #expect(!w.suspected)
        #expect(routed.count == 2)
    }

    @Test func refusalsNeverWipe() async {
        var wipes = 0
        let holder = HolderWatch { wipes += 1 }
        let w = RefusalWatch {}
        for n in 1...10 { w.onRefusals(n, phase: .unlocked) }
        #expect(w.suspected)
        #expect(!holder.onFailure(VaultFailure(.network, code: "token_revoked")))
        #expect(!holder.onFailure(VaultFailure(.other, code: "unreadable_result")))
        #expect(wipes == 0 && holder.count == 0)
    }
}

/// Erase-or-recover beside "Try again" once nothing has reached the vault service for 7 days. Mirrors vettid-android
/// `StuckScreensTest`.
@Suite struct StuckScreensTests {
    let day: Int64 = 24 * 60 * 60 * 1000
    var now: Int64 { 100 * day }

    @Test func aVaultUnreachableForSevenDaysOffersAWayOut() {
        #expect(StuckScreens.longUnreachable(.network, lastContactMs: now - 7 * day, nowMs: now))
        #expect(!StuckScreens.longUnreachable(.network, lastContactMs: now - 7 * day + 1, nowMs: now))
    }

    @Test func noLastContactKnownOffersNothing() {
        #expect(!StuckScreens.longUnreachable(.network, lastContactMs: nil, nowMs: now))
    }

    @Test func failuresWithTheirOwnWayOrNoneAreNotChanged() {
        let own: Set<FailureKind> = [.clock, .noVault, .localState, .eraseFailed, .unauthorized]
        for k in FailureKind.allCases {
            #expect(StuckScreens.longUnreachable(k, lastContactMs: now - 30 * day, nowMs: now) == !own.contains(k), "\(k)")
        }
    }

    @Test func aContactIsWrittenAtMostHourly() {
        let hour: Int64 = 60 * 60 * 1000
        #expect(StuckScreens.writeContact(nil, nowMs: now))
        #expect(!StuckScreens.writeContact(now - hour + 1, nowMs: now))
        #expect(StuckScreens.writeContact(now - hour, nowMs: now))
        #expect(StuckScreens.writeContact(now + hour, nowMs: now), "a clock set back")
    }
}
