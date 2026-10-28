import Foundation
import Testing
@testable import VettIDData
import VettIDCrypto
import VettIDKeys
import VettIDVault

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// A check on its way that the test holds until it lets it go.
final class CheckGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrivedValue = false

    var arrived: Bool { lock.withLock { arrivedValue } }

    func wait() async {
        await withCheckedContinuation { c in
            let go = lock.withLock {
                arrivedValue = true
                if open { return true }
                waiter = c
                return false
            }
            if go { c.resume() }
        }
    }

    func release() {
        let w = lock.withLock {
            open = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }
}

/// (IOS-PLAN §6.6; VAULT-MESSAGING §3.6.5 "Ask only for what is used") What the unlock's check leaves for the check screen: the
/// accepted PIN for a password-only retry, kept in memory only until the app leaves the front, the vault locks or is wiped,
/// another check or unlock comes; the tenth failure marked at once; an answer sent before another unlock, a lock or a wipe
/// dropped. Mirrors vettid-android `OwnerCheckManagerTest` ("the unlock keeps the PIN ...").
@MainActor
@Suite struct OwnerCheckUnlockPinTests {
    let now = OwnerCheckManager.instant("2026-10-06T12:00:00Z")!
    let stored = StoredBytes()
    let pin = "975310"
    let held = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":1,"hold":true}"#

    /// [sleep]: the wait for the status read after a failure (by default none: the count kept here may answer first).
    func manager(_ ops: FakeOwnerCheckOps, sleep: @escaping LockSleep = { _ in }) -> OwnerCheckManager {
        let stored = stored
        let now = now
        let m = OwnerCheckManager(ops: { ops }, load: { stored.bytes }, persist: { stored.bytes = $0 }, now: { now }, sleep: sleep)
        m.loadIfNeeded()
        return m
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    /// The tries left depend on whether the status read after the failure beat the fallback: not asserted.
    static func isBadPassword(_ r: OwnerCheckOutcome?) -> Bool {
        if case .badPassword? = r { return true }
        return false
    }

    func heldOps(_ error: (code: String, retryAfter: Int64)? = ("bad_password", 0)) -> FakeOwnerCheckOps {
        let ops = FakeOwnerCheckOps()
        ops.status = held
        ops.checkError = error
        return ops
    }

    /// A wrong password with a try left, or a backoff, keeps the PIN, once; nothing else does.
    @Test func theUnlockKeepsThePinForAPasswordOnlyRetry() async {
        let ops = heldOps()
        let m = manager(ops)
        await m.afterUnlock(pin: pin, password: "nope")
        #expect(Self.isBadPassword(m.unlockCheckOutcome))
        #expect(m.takeUnlockPin() == pin)
        #expect(m.takeUnlockPin() == nil, "once")
        // A backoff used no try: the PIN is kept too.
        ops.checkError = ("backoff", 300)
        await m.afterUnlock(pin: pin, password: "pw")
        #expect(m.unlockCheckOutcome == .backoff(retryAfterSeconds: 300))
        #expect(m.takeUnlockPin() == pin)
        // A pass, a wrong PIN, another failure, or nothing due: nothing to keep.
        ops.checkError = nil
        await m.afterUnlock(pin: pin, password: "pw")
        #expect(m.unlockCheckOutcome == .passed && m.takeUnlockPin() == nil)
        ops.status = held
        ops.checkError = ("bad_pin", 0)
        await m.afterUnlock(pin: pin, password: "pw")
        #expect(m.takeUnlockPin() == nil)
        ops.checkError = nil
        ops.status = #"{"state":"ok","deadline":"2026-10-07T12:00:00Z","interval_seconds":86400}"#
        let checks = ops.checks.count
        await m.afterUnlock(pin: pin, password: "pw")
        #expect(ops.checks.count == checks && m.takeUnlockPin() == nil)
    }

    /// The app not in front: never kept, and the spent try shows as the ordinary failure.
    @Test func nothingIsKeptWhileTheAppIsNotInFront() async {
        let m = manager(heldOps())
        m.setForeground(false)
        await m.afterUnlock(pin: pin, password: "nope")
        #expect(m.takeUnlockPin() == nil)
        #expect(Self.isBadPassword(m.unlockCheckOutcome))
        m.setForeground(true)
        await m.afterUnlock(pin: pin, password: "nope")
        #expect(m.takeUnlockPin() == pin)
    }

    /// The app leaves the front while the unlock's check is on its way: no PIN is kept (Android: "ON_STOP while the unlock and
    /// its check run").
    @Test func leavingTheFrontWhileTheCheckRunsKeepsNoPin() async {
        let ops = heldOps()
        let m = manager(ops)
        ops.onCheck = { _ in await m.setForeground(false) }
        await m.afterUnlock(pin: pin, password: "nope")
        #expect(m.takeUnlockPin() == nil)
        #expect(Self.isBadPassword(m.unlockCheckOutcome))
        // Back in front, another unlock keeps it again.
        ops.onCheck = nil
        m.setForeground(true)
        await m.afterUnlock(pin: pin, password: "nope")
        #expect(m.takeUnlockPin() == pin)
    }

    /// A lock of any reason, one made here, a wipe, another check and a stop of the collection end the kept PIN.
    @Test(arguments: [#"{"reason":"idle"}"#, #"{"reason":"owner_check"}"#, #"{"reason":"owner"}"#, "{}"])
    func anyLockEventEndsTheKeptPin(_ body: String) async {
        let m = manager(heldOps())
        await m.afterUnlock(pin: pin, password: "nope")
        m.onEvent(event("vault.locking", body))
        #expect(m.takeUnlockPin() == nil)
    }

    @Test func aLockHereAWipeAnotherCheckAndAStopEndTheKeptPin() async throws {
        let ops = heldOps()
        let m = manager(ops)
        await m.afterUnlock(pin: pin, password: "nope")
        m.onLockedHere()
        #expect(m.takeUnlockPin() == nil)
        await m.afterUnlock(pin: pin, password: "nope")
        m.clear()
        #expect(m.takeUnlockPin() == nil)
        await m.afterUnlock(pin: pin, password: "nope")
        _ = try await m.check(pin: pin, password: "pw")
        #expect(m.takeUnlockPin() == nil)
        await m.afterUnlock(pin: pin, password: "nope")
        m.forgetUnlockPin()
        #expect(m.takeUnlockPin() == nil)
    }

    /// The tenth failed check locks the vault (§3.6.4); the app says so at once, without `vault.locking`, and keeps no PIN.
    @Test func theTenthFailureMarksTheLockWithoutTheNotice() async {
        let ops = heldOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":9,"hold":true}"#
        ops.onCheck = { _ in ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":10,"hold":true}"# }
        // The vault's own count, read after the failure, marks the lock: the wait lets that read answer.
        let m = manager(ops, sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        await m.afterUnlock(pin: pin, password: "nope")
        #expect(m.unlockCheckOutcome == .badPassword(checksLeft: 0))
        #expect(m.lockedByOwnerCheck)
        #expect(m.takeUnlockPin() == nil)
    }

    /// Out of the front and back between the unlock's start and its check (the unlock request on its way): no PIN is kept,
    /// and every leave is counted.
    @Test func leavingTheFrontBeforeTheUnlockAnswersDropsThePin() async {
        let m = manager(heldOps())
        let left = m.startUnlockPin()
        m.setForeground(false)
        m.setForeground(true)
        #expect(m.leftFront == 1)
        await m.afterUnlock(pin: pin, password: "nope", left: left)
        #expect(Self.isBadPassword(m.unlockCheckOutcome))
        #expect(m.takeUnlockPin() == nil)
    }

    /// The late notice of an earlier lock, arriving while the unlock request is on its way: the vault was locked then, so
    /// the PIN the check after the opening leaves is kept.
    @Test func aLateLockNoticeDuringTheUnlockRequestKeepsThePin() async {
        let m = manager(heldOps())
        let left = m.startUnlockPin()
        m.onEvent(event("vault.locking", #"{"reason":"member"}"#))
        await m.afterUnlock(pin: pin, password: "nope", left: left)
        #expect(Self.isBadPassword(m.unlockCheckOutcome))
        #expect(m.takeUnlockPin() == pin)
    }

    /// A second unlock while the first one's check is on its way: the first answer opens nothing and shows nothing.
    @Test func aSecondUnlockDropsTheAnswerOfTheFirst() async {
        let ops = heldOps()
        let m = manager(ops)
        let gate = CheckGate()
        ops.onCheck = { index in if index == 1 { await gate.wait() } }
        let first = Task { @MainActor in await m.afterUnlock(pin: "111111", password: "nope") }
        while !gate.arrived { await Task.yield() }
        ops.checkError = nil
        await m.afterUnlock(pin: pin, password: "pw")
        #expect(m.unlockCheckOutcome == .passed)
        gate.release()
        await first.value
        #expect(m.unlockCheckOutcome == .passed, "the first answer was dropped")
        #expect(m.takeUnlockPin() == nil)
    }

    /// A lock made here, or a wipe, while the check is on its way: nothing is shown or kept afterwards.
    @Test(arguments: [true, false])
    func aLockOrAWipeDuringTheCheckDropsItsAnswer(wipe: Bool) async {
        let ops = heldOps()
        let m = manager(ops)
        ops.onCheck = { _ in await (wipe ? m.clear() : m.onLockedHere()) }
        await m.afterUnlock(pin: pin, password: "nope")
        #expect(m.unlockCheckOutcome == nil)
        #expect(m.takeUnlockPin() == nil)
    }
}

// swiftlint:enable line_length
