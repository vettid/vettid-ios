import Foundation
import Testing
import VettIDCrypto
import VettIDVault
@testable import VettIDData

/// (VAULT-MESSAGING 0.73.0 §3.6.5) The app's estimate of the tries left, and the read of the vault's state that sends no
/// check. Mirrors the part of vettid-android `OwnerCheckManagerTest` that came with "probably locked".
@MainActor
@Suite struct OwnerCheckEstimateTests {
    let now = OwnerCheckManager.instant("2026-10-06T12:00:00Z")!
    let stored = StoredBytes()
    let found = Found()

    @MainActor
    final class Found {
        var locked = 0
        /// The member API's `state`, nil: no answer; and what happens while it is asked.
        var memberState: String?
        var onMember: (@MainActor () -> Void)?
    }

    /// The waits for a status last until it answers or fails (it always does here).
    func manager(_ ops: FakeOwnerCheckOps) -> OwnerCheckManager {
        let stored = stored
        let found = found
        let now = now
        let m = OwnerCheckManager(
            ops: { ops }, load: { stored.bytes }, persist: { stored.bytes = $0 }, now: { now }, sleep: OwnerCheckManagerTests.waitForStatus,
            memberState: {
                found.onMember?()
                return found.memberState
            },
            onFoundLocked: { found.locked += 1 }
        )
        m.loadIfNeeded()
        return m
    }

    func opsAt(failures: Int) -> FakeOwnerCheckOps {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":\#(failures)}"#
        return ops
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    @Test func withNoCountReadSinceTheStartTheEstimateIsZero() async throws {
        let ops = opsAt(failures: 2)
        ops.statusFails = true
        let m = manager(ops)
        ops.checkError = ("bad_password", 0)
        #expect(try await m.check(pin: "975310", password: "nope") == .badPassword(checksLeft: 0, estimated: true))
        #expect(!m.lockedByOwnerCheck, "an estimate never marks the lock")
    }

    @Test func aCountReadSetsTheEstimateAndEachFailureWithoutAStatusSpendsOne() async throws {
        let ops = opsAt(failures: 2)
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        #expect(m.estimate == 8)
        ops.statusFails = true
        ops.checkError = ("bad_pin", 0)
        #expect(try await m.check(pin: "111111", password: "pw") == .badPin(checksLeft: 7, estimated: true))
        #expect(m.ownerCheck?.failures == 2, "only the vault's count is kept")
    }

    @Test func anUnansweredCheckSpendsOneOfTheEstimate() async throws {
        let ops = opsAt(failures: 2)
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        ops.checkUnanswered = true
        let r = try await m.check(pin: "975310", password: "pw")
        #expect(r == .failed(.noResponse, code: nil, estimatedLeft: 7))
        #expect(r.isUnanswered)
    }

    @Test func aPassedCheckEndsTheRunOfFailures() async throws {
        let ops = opsAt(failures: 9)
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        #expect(m.estimate == OwnerCheckView.maxFailures)
    }

    @Test func aForegroundReturnKeepsTheEstimateAndAnUnlockForgetsIt() async throws {
        let ops = opsAt(failures: 3)
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        ops.statusFails = true
        m.onOpened(afterUnlock: false)
        await settle()
        #expect(m.estimate == 7)
        m.onOpened()
        await settle()
        #expect(m.estimate == 0)
    }

    @Test func otherOperationsThatCountSpendTheEstimate() async throws {
        let m = manager(opsAt(failures: 0))
        try await m.refreshOwnerCheck()
        m.countedEnded(type: "pin.change")
        m.countedEnded(type: "credential.password.change")
        #expect(m.estimate == 8)
        // Not an operation that verifies the PIN: nothing changes.
        m.countedEnded(type: "feed.list")
        m.countedEnded(type: "vault.owner-check")
        #expect(m.estimate == 8)
    }

    @Test func noEstimateIsSaved() async throws {
        let m = manager(opsAt(failures: 4))
        try await m.refreshOwnerCheck()
        #expect(m.estimate == 6)
        let again = manager(opsAt(failures: 4))
        #expect(again.estimate == 0)
    }

    @Test func theProbeTakesOnlyTheVaultsAnswerOrTheApisLocked() async throws {
        let ops = opsAt(failures: 9)
        let m = manager(ops)
        // `vault.status` answers: open, whatever the API would say.
        found.memberState = "locked"
        #expect(await m.probeVault(lockCauseKnown: true) == .open)
        #expect(!m.lockedByOwnerCheck)
        // No answer from the vault: the API's `unlocked` is not an answer, nor is no answer.
        ops.statusFails = true
        found.memberState = "unlocked"
        #expect(await m.probeVault(lockCauseKnown: true) == .noAnswer)
        found.memberState = nil
        #expect(await m.probeVault(lockCauseKnown: true) == .noAnswer)
        #expect(found.locked == 0)
        // The API's `locked`: locked, and the app moves to its locked screen.
        found.memberState = "locked"
        #expect(await m.probeVault(lockCauseKnown: true) == .locked)
        #expect(m.lockedByOwnerCheck && !m.lockCauseUnknown)
        #expect(found.locked == 1)
    }

    @Test func aLockFoundAboveZeroHasNoKnownCause() async throws {
        let ops = opsAt(failures: 2)
        ops.statusFails = true
        let m = manager(ops)
        found.memberState = "locked"
        #expect(await m.probeVault(lockCauseKnown: false) == .locked)
        #expect(m.lockedByOwnerCheck && m.lockCauseUnknown)
        // An unlock ends it.
        await m.afterUnlock(pin: "975310", password: "pw")
        #expect(!m.lockedByOwnerCheck && !m.lockCauseUnknown)
    }

    @Test func aKnownCauseIsNeverDowngraded() async throws {
        let ops = opsAt(failures: 9)
        ops.statusFails = true
        let m = manager(ops)
        m.onEvent(event("vault.locking", #"{"reason":"owner_check"}"#))
        found.memberState = "locked"
        #expect(await m.probeVault(lockCauseKnown: false) == .locked)
        #expect(m.lockedByOwnerCheck && !m.lockCauseUnknown)
    }

    @Test func aProbeThatFinishesAfterTheMembersLockIsDropped() async throws {
        let ops = opsAt(failures: 9)
        ops.statusFails = true
        let m = manager(ops)
        found.memberState = "locked"
        found.onMember = { m.onLockedHere() }
        #expect(await m.probeVault(lockCauseKnown: true) == .noAnswer)
        #expect(!m.lockedByOwnerCheck && found.locked == 0)
    }

    @Test func aProbeThatFinishesAfterAWipeIsDropped() async throws {
        let ops = opsAt(failures: 9)
        ops.statusFails = true
        let m = manager(ops)
        found.memberState = "locked"
        found.onMember = { m.clear() }
        #expect(await m.probeVault(lockCauseKnown: true) == .noAnswer)
        #expect(!m.lockedByOwnerCheck)
    }

    @Test func relayReconnectsAreCounted() {
        let m = manager(opsAt(failures: 0))
        m.onRelayReconnected()
        m.onRelayReconnected()
        #expect(m.relayReconnects == 2)
    }

    /// Lets the manager's own reads finish.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
