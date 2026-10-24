import Foundation
import Testing
@testable import VettIDData
import VettIDCrypto
import VettIDVault

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// Release L (VAULT-MESSAGING §3.6.8): the idle lock in the app's owner check. Mirrors vettid-android
/// `OwnerCheckManagerTest`'s idle-lock cases, test for test.
@MainActor
@Suite struct OwnerCheckIdleLockTests {
    let now = OwnerCheckManager.instant("2026-10-06T12:00:00Z")!
    let stored = StoredBytes()
    let scale = ScaleBox()
    let deadline = "2026-10-06T11:00:00Z"
    let idleAt = "2026-10-13T11:00:00Z"

    final class ScaleBox: @unchecked Sendable {
        var value: UInt64 = 1
    }

    func manager(_ ops: FakeOwnerCheckOps) -> OwnerCheckManager {
        let stored = stored
        let now = now
        let scale = scale
        let m = OwnerCheckManager(
            ops: { ops }, load: { stored.bytes }, persist: { stored.bytes = $0 }, now: { now }, sleep: { _ in },
            timeScale: { scale.value }
        )
        m.loadIfNeeded()
        return m
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    func at(_ s: String) -> Date { OwnerCheckManager.instant(s)! }

    /// Before the deadline: `idle_lock_at` less `deadline` is the value in force (later on it can move, §3.6.8).
    func readBeforeTheDeadline(_ ops: FakeOwnerCheckOps, _ m: OwnerCheckManager) async throws {
        ops.status = #"{"state":"ok","deadline":"2026-10-06T13:00:00Z","interval_seconds":86400,"idle_lock_at":"2026-10-13T13:00:00Z"}"#
        try await m.refreshOwnerCheck()
        ops.status = #"{"state":"held","deadline":"\#(deadline)","interval_seconds":86400,"hold":true,"idle_lock_at":"\#(idleAt)"}"#
        try await m.refreshOwnerCheck()
    }

    /// `idle_lock_at` from the status and from vault.held, kept on the phone; a passed check drops it (the deadline moved).
    @Test func theIdleLocksTimeIsReadKeptAndDroppedWhenACheckMovesTheDeadline() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"\#(deadline)","interval_seconds":86400,"hold":true,"idle_lock_at":"\#(idleAt)"}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.idleLockAt == at(idleAt))
        #expect(m.ownerCheck?.idleAfterSeconds == 604_800)
        #expect(manager(FakeOwnerCheckOps()).ownerCheck?.idleLockAt == at(idleAt))
        m.onEvent(event("vault.held", #"{"deadline":"\#(deadline)","waiting":{"messages":1},"idle_lock_at":"2026-10-12T11:00:00Z"}"#))
        #expect(m.ownerCheck?.idleLockAt == at("2026-10-12T11:00:00Z"))
        m.onEvent(event("vault.held", #"{"waiting":{"messages":2}}"#))
        #expect(m.ownerCheck?.idleLockAt == at("2026-10-12T11:00:00Z"))
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        #expect(m.ownerCheck?.idleLockAt == nil)
        // A vault before L: none.
        ops.status = #"{"state":"ok","deadline":"\#(deadline)","interval_seconds":86400}"#
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.idleLockAt == nil)
    }

    /// `vault.locking{reason: "idle"}`: said until the vault opens again, with how long past the deadline it was.
    @Test func anIdleLockIsSaidUntilTheVaultOpensAgain() async throws {
        let ops = FakeOwnerCheckOps()
        let m = manager(ops)
        try await readBeforeTheDeadline(ops, m)
        #expect(m.idleLocked == nil)
        m.onEvent(event("vault.locking", #"{"reason":"owner_check"}"#))
        #expect(m.idleLocked == nil)
        m.onEvent(event("vault.locking", #"{"reason":"idle","unlock_id":"\#(String(repeating: "a", count: 32))"}"#))
        #expect(m.idleLocked == IdleLocked(afterSeconds: 604_800))
        #expect(manager(FakeOwnerCheckOps()).idleLocked == IdleLocked(afterSeconds: 604_800))
        m.onOpened()
        #expect(m.idleLocked == nil)
        #expect(manager(FakeOwnerCheckOps()).idleLocked == nil)
    }

    /// Without the notice (the phone was off): a time past the `idle_lock_at` last read says why; before it, nothing.
    @Test func withoutTheNoticeTheTimeLastReadSaysWhy() async throws {
        let ops = FakeOwnerCheckOps()
        let m = manager(ops)
        try await readBeforeTheDeadline(ops, m)
        #expect(m.idleLockedNow(at(idleAt).addingTimeInterval(-1)) == nil)
        #expect(m.idleLockedNow(at(idleAt)) == IdleLocked(afterSeconds: 604_800))
        ops.status = #"{"state":"held","deadline":"\#(deadline)","interval_seconds":86400,"hold":true}"#
        try await m.refreshOwnerCheck()
        #expect(m.idleLockedNow(at(idleAt).addingTimeInterval(60)) == nil)
    }

    /// An unlock past the idle lock's time moves `idle_lock_at` to one hour after it; the notice still says how long past the
    /// deadline the vault was set to wait, not that time plus the gap and the hour.
    @Test func theTimeSaidIsTheValueInForceNotAMovedIdleLockTime() async throws {
        let ops = FakeOwnerCheckOps()
        let m = manager(ops)
        try await readBeforeTheDeadline(ops, m)
        ops.status = #"{"state":"held","deadline":"\#(deadline)","interval_seconds":86400,"hold":true,"idle_lock_at":"2026-10-14T15:17:00Z"}"#
        try await m.refreshOwnerCheck()
        m.onEvent(event("vault.locking", #"{"reason":"idle"}"#))
        #expect(m.idleLocked == IdleLocked(afterSeconds: 604_800))
        // Never read before the deadline: not known (the plain text), never a made-up figure.
        stored.bytes = nil
        let freshOps = FakeOwnerCheckOps()
        freshOps.status = #"{"state":"held","deadline":"\#(deadline)","interval_seconds":86400,"idle_lock_at":"2026-10-14T15:17:00Z"}"#
        let fresh = manager(freshOps)
        try await fresh.refreshOwnerCheck()
        fresh.onEvent(event("vault.locking", #"{"reason":"idle"}"#))
        #expect(fresh.idleLocked == IdleLocked(afterSeconds: nil))
    }

    /// After the member's own lock on this phone, the unlock screen does not say it locked itself.
    @Test func aLockMadeHereIsNotSaidToBeAnIdleLock() async throws {
        let ops = FakeOwnerCheckOps()
        let m = manager(ops)
        try await readBeforeTheDeadline(ops, m)
        let later = at(idleAt).addingTimeInterval(60)
        m.onLockedHere()
        #expect(m.idleLockedNow(later) == nil)
        #expect(manager(FakeOwnerCheckOps()).idleLockedNow(later) == nil)
        m.onOpened()
        #expect(m.idleLockedNow(later) == IdleLocked(afterSeconds: 604_800))
        // The vault's own notice is said whoever locked before.
        m.onLockedHere()
        m.onEvent(event("vault.locking", #"{"reason":"idle"}"#))
        #expect(m.idleLockedNow(later) == IdleLocked(afterSeconds: 604_800))
    }

    /// Locked for another reason than the idle lock (a notice with none, `recovery`, `owner_check`): `idle_lock_at` passing
    /// later does not say it locked itself, and a restart does not forget it.
    @Test(arguments: [#"{}"#, #"{"reason":"recovery"}"#, #"{"reason":"owner_check"}"#])
    func aLockForAnotherReasonIsNotSaidToBeAnIdleLock(body: String) async throws {
        let ops = FakeOwnerCheckOps()
        let m = manager(ops)
        try await readBeforeTheDeadline(ops, m)
        let later = at(idleAt).addingTimeInterval(60)
        m.onEvent(event("vault.locking", body))
        #expect(m.idleLockedNow(later) == nil)
        #expect(manager(FakeOwnerCheckOps()).idleLockedNow(later) == nil)
        m.onOpened()
        #expect(m.idleLockedNow(later) == IdleLocked(afterSeconds: 604_800))
    }

    /// A flag set before any view of the check was read (a kill right after) is kept, and the view read later does not drop it.
    @Test func theFlagsAreKeptWithoutAViewOfTheCheck() async throws {
        let m = manager(FakeOwnerCheckOps())
        #expect(m.ownerCheck == nil)
        m.onEvent(event("vault.locking", #"{"reason":"idle"}"#))
        let restarted = manager(FakeOwnerCheckOps())
        #expect(restarted.ownerCheck == nil)
        #expect(restarted.idleLocked == IdleLocked(afterSeconds: nil))
        restarted.onOpened()
        stored.bytes = nil
        let other = manager(FakeOwnerCheckOps())
        other.onLockedHere()
        let again = manager(FakeOwnerCheckOps())
        #expect(again.ownerCheck == nil)
        let ops = FakeOwnerCheckOps()
        try await readBeforeTheDeadline(ops, again)
        #expect(again.idleLockedNow(at(idleAt).addingTimeInterval(60)) == nil)
        #expect(manager(FakeOwnerCheckOps()).idleLockedNow(at(idleAt).addingTimeInterval(60)) == nil)
    }

    /// The setting: none for a vault before L; a shorter value in force at once, a longer one after the next check, and the
    /// lowest set since the last check stays in force (owner decision 2026-10-23).
    @Test func theIdleLockSettingShorterAtOnceLongerAfterTheNextCheck() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T11:00:00Z","interval_seconds":86400}"#
        let m = manager(ops)
        try await m.refreshIdleLockSetting()
        #expect(m.idleLockSetting == nil)
        ops.settings = [OwnerCheckManager.keyIdle: "604800"]
        try await m.refreshIdleLockSetting()
        #expect(m.idleLockSetting == IdleLockSetting(seconds: 604_800))
        try await m.setIdleLockAfter(seconds: 2_592_000)
        #expect(ops.sets.last == [OwnerCheckManager.keyIdle: "2592000"])
        #expect(m.idleLockSetting?.afterNextCheck == true)
        #expect(m.idleLockSetting?.inForceSeconds == 604_800)
        try await m.setIdleLockAfter(seconds: 3_600)
        #expect(m.idleLockSetting == IdleLockSetting(seconds: 3_600))
        try await m.setIdleLockAfter(seconds: 1_209_600)
        #expect(m.idleLockSetting == IdleLockSetting(seconds: 1_209_600, inForceSeconds: 3_600))
        // Kept across a restart.
        let again = manager(ops)
        try await again.refreshIdleLockSetting()
        #expect(again.idleLockSetting == IdleLockSetting(seconds: 1_209_600, inForceSeconds: 3_600))
        #expect(try await again.check(pin: "975310", password: "pw") == .passed)
        #expect(again.idleLockSetting == IdleLockSetting(seconds: 1_209_600))
        // Only the choices; no "never".
        await #expect(throws: VaultFailure.self) { try await again.setIdleLockAfter(seconds: 0) }
        await #expect(throws: VaultFailure.self) { try await again.setIdleLockAfter(seconds: 3_599) }
        #expect(IdleLockSetting.choices == [3_600, 86_400, 604_800, 1_209_600, 2_592_000])
    }

    /// Once a check puts a longer value in force, the idle notice says that value; on a scaled vault, as it runs there.
    @Test func aCheckPuttingALongerValueInForceChangesTheTimeSaid() async throws {
        let ops = FakeOwnerCheckOps()
        ops.settings = [OwnerCheckManager.keyIdle: "604800"]
        let m = manager(ops)
        try await readBeforeTheDeadline(ops, m)
        try await m.refreshIdleLockSetting()
        try await m.setIdleLockAfter(seconds: 2_592_000)
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        m.onEvent(event("vault.locking", #"{"reason":"idle"}"#))
        #expect(m.idleLocked == IdleLocked(afterSeconds: 2_592_000))
        // On a scaled vault (staging, 24): as it runs there.
        scale.value = 24
        ops.status = #"{"state":"held","deadline":"\#(deadline)","interval_seconds":86400,"hold":true}"#
        try await m.refreshOwnerCheck()
        try await m.setIdleLockAfter(seconds: 1_209_600)
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        m.onEvent(event("vault.locking", #"{"reason":"idle"}"#))
        #expect(m.idleLocked == IdleLocked(afterSeconds: 50_400))
    }

    /// Keep the lowest since the last check, not the lowest of the values set: 7 d, then 30 d, then 14 d keeps 7 d.
    @Test func theLowestSinceTheLastCheckIsTheValueInForceNotTheLastSet() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T11:00:00Z","interval_seconds":86400}"#
        ops.settings = [OwnerCheckManager.keyIdle: "604800"]
        let m = manager(ops)
        try await m.refreshIdleLockSetting()
        try await m.setIdleLockAfter(seconds: 2_592_000)
        try await m.setIdleLockAfter(seconds: 1_209_600)
        #expect(m.idleLockSetting == IdleLockSetting(seconds: 1_209_600, inForceSeconds: 604_800))
        #expect(m.idleLockSetting?.afterNextCheck == true)
    }

    /// A longer value set, the app killed, a check passed before the setting was read again; the vault then locks with the
    /// longer value, so the notice must not say the shorter one.
    @Test func aCheckAfterARestartWithALongerValueWaitingSaysTheTimeIsNotKnown() async throws {
        let ops = FakeOwnerCheckOps()
        ops.settings = [OwnerCheckManager.keyIdle: "604800"]
        let m = manager(ops)
        try await readBeforeTheDeadline(ops, m)
        try await m.refreshIdleLockSetting()
        try await m.setIdleLockAfter(seconds: 2_592_000)
        // The process ends; the next one does not open Settings before the check.
        let next = manager(ops)
        #expect(next.idleLockSetting == nil)
        #expect(try await next.check(pin: "975310", password: "pw") == .passed)
        next.onEvent(event("vault.locking", #"{"reason":"idle"}"#))
        #expect(next.idleLocked == IdleLocked(afterSeconds: nil))
    }
}

// swiftlint:enable line_length

/// The idle lock's time as the screens and the notification say it. Mirrors vettid-android `FeedNotifierTest`
/// `durationsAreSaidAsOnTheScreens`.
@Suite struct IdleLockTextTests {
    @Test func durationsAreSaidAsOnTheScreens() {
        #expect(IdleLockText.duration(3_600) == "1 hour")
        // As the setting names it.
        #expect(IdleLockText.duration(86_400) == "1 day")
        #expect(IdleLockText.duration(604_800) == "7 days")
        #expect(IdleLockText.duration(2_592_000) == "30 days")
        #expect(IdleLockText.duration(25_200) == "7 hours")
        #expect(IdleLockText.duration(150) == "150 seconds")
        #expect(IdleLockText.duration(900) == "15 minutes")
    }
}
