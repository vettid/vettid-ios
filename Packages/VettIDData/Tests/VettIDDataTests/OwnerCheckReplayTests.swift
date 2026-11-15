import Foundation
import Testing
@testable import VettIDData
import VettIDCrypto
import VettIDVault

/// (ANDROID-PLAN 0.1.132 Notifications 7; owner decisions of 2026-11-15) The count of checks passed with the vault open
/// (``OwnerCheckView/passes``) and when it makes the waiting asks' replay due. As vettid-android `OwnerCheckManagerTest`'s
/// replay cases.
@MainActor
@Suite struct OwnerCheckReplayTests {
    let now = OwnerCheckManager.instant("2026-10-06T12:00:00Z")!
    let stored = StoredBytes()

    func manager(_ ops: FakeOwnerCheckOps) -> OwnerCheckManager {
        let stored = stored, now = now
        let m = OwnerCheckManager(ops: { ops }, load: { stored.bytes }, persist: { stored.bytes = $0 }, now: { now }, sleep: { _ in })
        m.loadIfNeeded()
        return m
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    /// (ANDROID-PLAN 0.1.132 Notifications 7) A replay is due when a counted check ends the gate the feed uses (the state,
    /// or the deadline passed by the clock alone): this phone's check (not an unlock's own) or another device's
    /// (`sync.event{owner_check}`); never a status read.
    @Test func aReplayIsDueOnlyForACountedPass() async throws {
        let ops = FakeOwnerCheckOps()
        let m = manager(ops)
        var due: [String] = []
        m.onReplayDue = { pass, stateEnded in due.append("\(pass):\(stateEnded)") }
        let held = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":true}"#
        let clockDue = #"{"state":"ok","deadline":"2026-10-06T11:30:00Z","interval_seconds":86400,"hold":true}"#
        ops.status = clockDue
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.gated(now) == true && due.isEmpty, "due by the clock alone")
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        #expect(due == ["here:false"])
        // Another device's check, as `sync.event{owner_check}`.
        ops.status = held
        try await m.refreshOwnerCheck()
        m.onEvent(event("sync.event", #"{"kind":"owner_check","deadline":"2026-10-07T18:00:00Z"}"#))
        #expect(due == ["here:false", "elsewhere:true"])
        // A status read that finds the vault ok again (another device's check not told, a restart) is not a pass.
        ops.status = held
        try await m.refreshOwnerCheck()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T18:00:00Z","interval_seconds":86400,"hold":true}"#
        try await m.refreshOwnerCheck()
        #expect(due.count == 2)
        // The unlock's own check, after a held status and by the clock path; a cancelled recovery's.
        ops.status = held
        try await m.refreshOwnerCheck()
        await m.afterUnlock(pin: "975310", password: "pw")
        #expect(m.unlockCheckOutcome == .passed)
        ops.status = clockDue
        await m.afterUnlock(pin: "975310", password: "pw")
        #expect(m.unlockCheckOutcome == .passed)
        ops.status = held
        try await m.refreshOwnerCheck()
        await m.afterCancelledRecovery(pin: "975310", password: "pw")
        #expect(m.ownerCheck?.state == .ok)
        #expect(due.count == 2, "\(due)")
        // A check while not gated is counted but ends nothing.
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        #expect(due.count == 2)
        // A shortened interval moves the deadline earlier: the next pass after the gate still counts.
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:59:00Z","interval_seconds":3600,"hold":true}"#
        try await m.refreshOwnerCheck()
        ops.answerDeadline = "2026-10-06T13:00:00Z"
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        #expect(due == ["here:false", "elsewhere:true", "here:true"])
    }

    /// A restart: the held view kept on the phone, then a status read that says ok, is no pass.
    @Test func aRestartThenAStatusReadIsNoPass() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":true}"#
        try await manager(ops).refreshOwnerCheck()
        let again = manager(ops)
        #expect(again.ownerCheck?.state == .held)
        var due = 0
        again.onReplayDue = { _, _ in due += 1 }
        ops.status = #"{"state":"ok","deadline":"2026-10-07T12:00:00Z","interval_seconds":86400,"hold":true}"#
        try await again.refreshOwnerCheck()
        #expect(again.ownerCheck?.gated(now) == false && due == 0)
    }

    /// A stale status read finishing after a pass cannot publish a lower count: the count is stamped as the value is set.
    @Test func aStaleStatusReadNeverTakesTheCountBack() async throws {
        let ops = FakeOwnerCheckOps()
        let m = manager(ops)
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":true}"#
        try await m.refreshOwnerCheck()
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        #expect(m.ownerCheck?.passes == 1)
        try await m.refreshOwnerCheck() // the held status again, as a read begun before the check would bring it
        #expect(m.ownerCheck?.state == .held && m.ownerCheck?.passes == 1)
        var due = 0
        m.onReplayDue = { _, _ in due += 1 }
        ops.status = #"{"state":"ok","deadline":"2026-10-07T12:00:00Z","interval_seconds":86400,"hold":true}"#
        try await m.refreshOwnerCheck()
        #expect(due == 0, "the fresh status after the stale one is no new pass")
    }

    /// ``OwnerCheckView/replayDue(from:to:at:)``: gated before and not after, and the count rose.
    @Test func whenAReplayIsDue() {
        let past = now.addingTimeInterval(-3_600), next = now.addingTimeInterval(86_400), sooner = now.addingTimeInterval(3_600)
        func view(_ state: OwnerCheckState, _ deadline: Date?, passes: Int) -> OwnerCheckView {
            var v = OwnerCheckView(state: state, deadline: deadline)
            v.passes = passes
            return v
        }
        let held = view(.held, past, passes: 1), due = view(.due, past, passes: 1), clockDue = view(.ok, past, passes: 1)
        #expect(OwnerCheckView.replayDue(from: held, to: view(.ok, next, passes: 2), at: now), "held to ok in one change")
        #expect(OwnerCheckView.replayDue(from: due, to: view(.ok, next, passes: 2), at: now))
        #expect(OwnerCheckView.replayDue(from: clockDue, to: view(.ok, next, passes: 2), at: now), "due by the clock alone")
        #expect(OwnerCheckView.replayDue(from: held, to: view(.ok, sooner, passes: 2), at: now), "an earlier deadline")
        #expect(!OwnerCheckView.replayDue(from: held, to: view(.ok, next, passes: 1), at: now), "no pass counted: a status read")
        #expect(!OwnerCheckView.replayDue(from: held, to: view(.ok, next, passes: 0), at: now), "never backwards")
        #expect(!OwnerCheckView.replayDue(from: view(.ok, next, passes: 1), to: view(.ok, next, passes: 2), at: now), "not gated before")
        #expect(!OwnerCheckView.replayDue(from: held, to: view(.due, past, passes: 2), at: now), "still gated")
        #expect(!OwnerCheckView.replayDue(from: held, to: nil, at: now), "forgotten")
        #expect(!OwnerCheckView.replayDue(from: nil, to: view(.ok, next, passes: 2), at: now), "first read")
    }
}
