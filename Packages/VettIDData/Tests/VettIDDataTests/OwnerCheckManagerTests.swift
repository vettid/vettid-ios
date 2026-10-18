import Foundation
import Testing
@testable import VettIDData
import VettIDCrypto
import VettIDKeys
import VettIDVault

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// The vault's operations as the owner check meets them: scripted statuses and answers, every check recorded.
final class FakeOwnerCheckOps: OwnerCheckOps, @unchecked Sendable {
    private let lock = NSLock()
    private var statusJSON: String?
    private var checkErrorValue: (code: String, retryAfter: Int64)?
    private var presentRecordedValue: Bool?
    private var presentRecordedAtValue: String?
    private var counterValue = "ok"
    private var answerDeadlineValue: String? = "2026-10-07T12:00:00Z"
    private var checksValue: [[String?]] = []
    private var setsValue: [[String: String]] = []

    /// `vault.status`'s `owner_check` as its JSON text, or nil (a vault that sends none).
    var status: String? {
        get { lock.withLock { statusJSON } }
        set { lock.withLock { statusJSON = newValue } }
    }

    /// The vault's refusal of the next checks, as the vault client maps it (with a backoff's `retry_after`).
    var checkError: (code: String, retryAfter: Int64)? {
        get { lock.withLock { checkErrorValue } }
        set { lock.withLock { checkErrorValue = newValue } }
    }

    /// (Release R) The answer's `recovery.present_recorded`, and the status's `recovery.present_recorded_at`.
    var presentRecorded: Bool? {
        get { lock.withLock { presentRecordedValue } }
        set { lock.withLock { presentRecordedValue = newValue } }
    }

    var presentRecordedAt: String? {
        get { lock.withLock { presentRecordedAtValue } }
        set { lock.withLock { presentRecordedAtValue = newValue } }
    }

    var counter: String {
        get { lock.withLock { counterValue } }
        set { lock.withLock { counterValue = newValue } }
    }

    var answerDeadline: String? {
        get { lock.withLock { answerDeadlineValue } }
        set { lock.withLock { answerDeadlineValue = newValue } }
    }

    /// Each check's pin, password, hold and hold_off_until.
    var checks: [[String?]] { lock.withLock { checksValue } }
    var sets: [[String: String]] { lock.withLock { setsValue } }

    func statusAndRecovery() async throws -> (OwnerCheckStatus?, RecoveryStatus?) {
        let (st, at, counter) = lock.withLock { (statusJSON, presentRecordedAtValue, counterValue) }
        let recovery = try VaultJSON.decode(RecoveryStatus.self, Array((#"{"state":"armed","counter":"\#(counter)""# + (at.map { #","present_recorded_at":"\#($0)""# } ?? "") + "}").utf8))
        return (try st.map { try VaultJSON.decode(OwnerCheckStatus.self, Array($0.utf8)) }, recovery)
    }

    func check(pin: String, password: String, hold: Bool?, holdOffUntil: String?) async throws -> OwnerCheckPassed {
        let (err, recorded, deadline) = lock.withLock {
            checksValue.append([pin, password, hold.map { String($0) }, holdOffUntil])
            return (checkErrorValue, presentRecordedValue, answerDeadlineValue)
        }
        if let err { throw VaultFailure(VaultFailures.opFailure(err.code), code: err.code, retryAfterSeconds: err.retryAfter) }
        var o = #"{"interval_seconds":86400,"hold":\#(hold ?? true)"#
        if let deadline { o += #","deadline":"\#(deadline)""# }
        if let holdOffUntil { o += #","hold_off_until":"\#(holdOffUntil)""# }
        if let recorded { o += #","recovery":{"state":"armed","present_recorded":\#(recorded)}"# }
        return try VaultJSON.decode(OwnerCheckPassed.self, Array((o + "}").utf8))
    }

    func settingsGet() async throws -> VaultSettings { VaultSettings(version: 7, values: [:]) }

    func settingsSet(version: UInt64, set: [(key: String, json: String)]) async throws {
        lock.withLock { setsValue.append(Dictionary(uniqueKeysWithValues: set.map { ($0.key, $0.json) })) }
    }
}

/// What the owner check keeps on the phone.
@MainActor
final class StoredBytes {
    var bytes: [UInt8]?
}

/// The app's side of the daily owner check (VAULT-MESSAGING 0.13.0 §3.6). Mirrors vettid-android
/// `OwnerCheckManagerTest`, test for test (its feed notices come with the Notifications screen, IOS-PLAN §8 I2.3).
@MainActor
@Suite struct OwnerCheckManagerTests {
    let now = OwnerCheckManager.instant("2026-10-06T12:00:00Z")!
    let stored = StoredBytes()
    let passed = Counter()

    final class Counter: @unchecked Sendable {
        var count = 0
    }

    func manager(_ ops: FakeOwnerCheckOps, onRecoveryStatus: @escaping @MainActor (RecoveryStatus?, Int) -> Void = { _, _ in }) -> OwnerCheckManager {
        let stored = stored
        let passed = passed
        let now = now
        let m = OwnerCheckManager(
            ops: { ops }, load: { stored.bytes }, persist: { stored.bytes = $0 }, onPassed: { passed.count += 1 },
            onRecoveryStatus: onRecoveryStatus, now: { now }, sleep: { _ in }
        )
        m.loadIfNeeded()
        return m
    }

    func event(_ type: String, _ body: String, ts: Date? = nil) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: ts ?? now, body: Array(body.utf8)))
    }

    /// Lets the manager's own reads finish.
    func settle(_ done: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func statusGatesPastTheDeadlineAndSurvivesARestart() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":3,"hold":true}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        let v = try #require(m.ownerCheck)
        // The vault said ok, but the deadline has passed: the app is gated by the clock too (§3.6.3).
        #expect(v.gated(now))
        #expect(v.checksLeft == 7)
        // Kept on the phone: a locked vault past its deadline asks for the password with the PIN (§3.6.5).
        let again = manager(FakeOwnerCheckOps())
        #expect(again.ownerCheck?.gated(now) == true)
        #expect(again.ownerCheck?.failures == 3)
    }

    /// What is waiting survives a restart, and so does the `ts` of the `vault.held` it came from (an older one redelivered
    /// after the restart does not overwrite it); unknown stays unknown, never zero.
    @Test func waitingCountsAndTheirTimeSurviveARestart() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":true}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.waiting == nil, "the vault has not said yet")
        #expect(manager(FakeOwnerCheckOps()).ownerCheck?.waiting == nil)
        m.onEvent(event("vault.held", #"{"deadline":"2026-10-06T11:00:00Z","waiting":{"messages":2,"requests":0,"calls":1,"other":0}}"#))
        let again = manager(FakeOwnerCheckOps())
        #expect(again.ownerCheck?.waiting == WaitingCounts(messages: 2, calls: 1))
        again.onEvent(event("vault.held", #"{"waiting":{"messages":0}}"#, ts: now.addingTimeInterval(-60)))
        #expect(again.ownerCheck?.waiting == WaitingCounts(messages: 2, calls: 1))
        again.onEvent(event("vault.held", #"{"waiting":{"messages":5}}"#, ts: now.addingTimeInterval(60)))
        #expect(manager(FakeOwnerCheckOps()).ownerCheck?.waiting == WaitingCounts(messages: 5))
    }

    /// VAULT-MESSAGING 0.19.0: `vault.status`'s `owner_check.waiting`, while due or held; optional.
    @Test func theStatusSaysWhatIsWaitingWhenTheVaultSendsIt() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"due","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":false,"waiting":{"messages":4,"requests":1,"calls":0,"other":0}}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.waiting == WaitingCounts(messages: 4, requests: 1))
        // An older vault: what vault.held said stays.
        ops.status = #"{"state":"due","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":false}"#
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.waiting == WaitingCounts(messages: 4, requests: 1))
        // Zero is zero when the vault says so.
        ops.status = #"{"state":"due","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":false,"waiting":{"messages":0,"requests":0,"calls":0,"other":0}}"#
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.waiting == WaitingCounts())
        // Parsed from the wire as optional.
        let with = try VaultJSON.decode(OwnerCheckStatus.self, Array(#"{"state":"held","waiting":{"messages":1,"requests":2,"calls":3,"other":4}}"#.utf8))
        #expect(with.waiting?.calls == 3)
        #expect(try VaultJSON.decode(OwnerCheckStatus.self, Array(#"{"state":"held"}"#.utf8)).waiting == nil)
    }

    @Test func earlyWarningFromOneHourBefore() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"\#(OwnerCheckManager.format(now.addingTimeInterval(59 * 60)))","interval_seconds":86400}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.warning(now) == true)
        ops.status = #"{"state":"ok","deadline":"\#(OwnerCheckManager.format(now.addingTimeInterval(61 * 60)))","interval_seconds":86400}"#
        try await m.refreshOwnerCheck()
        #expect(m.ownerCheck?.warning(now) == false)
    }

    @Test func heldCountsAndAPassedCheck() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":true}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        m.onEvent(event("vault.held", #"{"deadline":"2026-10-06T11:00:00Z","waiting":{"messages":3,"requests":1,"calls":0,"other":2}}"#))
        #expect(m.ownerCheck?.waiting == WaitingCounts(messages: 3, requests: 1, other: 2))
        #expect(m.ownerCheck?.state == .held)
        // An older vault.held does not replace a newer one (§3.6.3: the newest by ts).
        m.onEvent(event("vault.held", #"{"waiting":{"messages":1}}"#, ts: now.addingTimeInterval(-60)))
        #expect(m.ownerCheck?.waiting?.messages == 3)

        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        #expect(ops.checks == [["975310", "pw", nil, nil]])
        let v = try #require(m.ownerCheck)
        #expect(v.state == .ok && v.deadline == OwnerCheckManager.instant("2026-10-07T12:00:00Z") && v.waiting == nil)
        #expect(passed.count == 1, "the catch-up")
    }

    @Test func holdOffRidesOnTheCheckAndIsClampedToThirtyDays() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T00:00:00Z","interval_seconds":86400}"#
        let m = manager(ops)
        _ = try await m.check(pin: "975310", password: "pw", holdOff: HoldOff(until: now.addingTimeInterval(31 * 86_400)))
        let sent = try #require(ops.checks.first)
        #expect(sent[2] == "false")
        let u = try #require(OwnerCheckManager.instant(sent[3]))
        #expect(u <= now.addingTimeInterval(30 * 86_400) && u > now.addingTimeInterval(29 * 86_400))
        #expect(m.ownerCheck?.holdOff(now) == true)

        // Off until the member turns it on: no end date.
        _ = try await m.check(pin: "975310", password: "pw", holdOff: HoldOff(until: nil))
        #expect(ops.checks.last == ["975310", "pw", "false", nil])

        // On: a plain settings.set.
        try await m.turnHoldOn()
        #expect(ops.sets == [["owner_check.hold": "true"]])
        #expect(m.ownerCheck?.holdOff(now) == false)
    }

    @Test func failedChecksSayWhichEntryAndHowManyAreLeft() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":0}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        ops.checkError = ("bad_pin", 0)
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":1}"#
        #expect(try await m.check(pin: "111111", password: "pw") == .badPin(checksLeft: 9))
        ops.checkError = ("bad_password", 0)
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":2}"#
        #expect(try await m.check(pin: "975310", password: "nope") == .badPassword(checksLeft: 8))
        ops.checkError = ("backoff", 300)
        #expect(try await m.check(pin: "975310", password: "pw") == .backoff(retryAfterSeconds: 300))
        ops.checkError = ("utk_invalid", 0)
        #expect(try await m.check(pin: "975310", password: "pw") == .failed(VaultFailures.opFailure("utk_invalid"), code: "utk_invalid"))
        // Ten failures lock the vault (§3.6.4).
        m.onEvent(event("vault.locking", #"{"reason":"owner_check"}"#))
        #expect(m.lockedByOwnerCheck)
    }

    /// The tenth failure locks the vault and then nothing answers the status: the count kept here goes up by one.
    @Test func withoutAStatusTheCountKeptHereGoesUp() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":8}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        ops.status = nil
        ops.checkError = ("bad_password", 0)
        #expect(try await m.check(pin: "975310", password: "nope") == .badPassword(checksLeft: 1))
    }

    @Test func aRefusedRequestGatesAndTheUnlockSendsTheCheck() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T00:00:00Z","interval_seconds":86400}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        ops.status = #"{"state":"due","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"hold":false}"#
        m.onRequired()
        #expect(m.ownerCheck?.gated(now) == true)
        await settle { m.ownerCheck?.state == .due }
        #expect(m.ownerCheck?.state == .due)

        // Locked past the deadline: one screen for both, the check right after the unlock (§3.6.5).
        await m.afterUnlock(pin: "975310", password: "pw")
        #expect(m.unlockCheckOutcome == .passed)
        #expect(ops.checks == [["975310", "pw", nil, nil]])
        m.consumeUnlockCheckOutcome()
        #expect(m.unlockCheckOutcome == nil)

        // Not past the deadline: no check.
        ops.status = #"{"state":"ok","deadline":"2026-10-07T12:00:00Z","interval_seconds":86400}"#
        await m.afterUnlock(pin: "975310", password: "pw")
        #expect(ops.checks.count == 1)
    }

    @Test func intervalIsOneToTwentyFourHours() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T00:00:00Z","interval_seconds":86400}"#
        let m = manager(ops)
        try await m.setCheckInterval(seconds: 3_600)
        #expect(ops.sets == [["owner_check.interval_seconds": "3600"]])
        await #expect(throws: VaultFailure.self) { try await m.setCheckInterval(seconds: 90_000) }
        await #expect(throws: VaultFailure.self) { try await m.setCheckInterval(seconds: 600) }
    }

    /// Release R (§11.14.5): `present_recorded: false` starts the presence notice; a later recorded presence ends it.
    @Test func thePresenceNoticeFollowsTheVault() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T12:00:00Z","interval_seconds":86400,"hold":true}"#
        ops.presentRecorded = false
        let m = manager(ops)
        #expect(try await m.check(pin: "975310", password: "pw") == .passed)
        #expect(m.presenceUnrecorded)
        // Kept across a restart.
        #expect(manager(FakeOwnerCheckOps()).presenceUnrecorded)
        // A presence recorded before that check (its time: the deadline less the interval) does not end it.
        ops.presentRecordedAt = "2026-10-06T11:00:00Z"
        try await m.refreshOwnerCheck()
        #expect(m.presenceUnrecorded)
        // One recorded since does.
        ops.presentRecordedAt = "2026-10-06T12:01:00Z"
        try await m.refreshOwnerCheck()
        #expect(!m.presenceUnrecorded)
        // So does a later answer that says it was recorded.
        _ = try await m.check(pin: "975310", password: "pw")
        #expect(m.presenceUnrecorded)
        ops.presentRecorded = true
        _ = try await m.check(pin: "975310", password: "pw")
        #expect(!m.presenceUnrecorded)
    }

    /// Before release R the answer has no `recovery`: nothing changes.
    @Test func noPresenceNoticeBeforeReleaseR() async throws {
        let m = manager(FakeOwnerCheckOps())
        _ = try await m.check(pin: "975310", password: "pw")
        #expect(!m.presenceUnrecorded)
    }

    /// ANDROID-PLAN "Other screens": after a cancel from the app the check goes at once; one that fails asks for the
    /// screen.
    @Test func theCheckAfterACancelledRecovery() async {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T12:00:00Z","interval_seconds":86400,"hold":true}"#
        let m = manager(ops)
        await m.afterCancelledRecovery(pin: "975310", password: "pw")
        #expect(ops.checks.count == 1 && !m.checkAfterCancel)
        ops.checkError = ("bad_password", 0)
        await m.afterCancelledRecovery(pin: "975310", password: "wrong")
        #expect(ops.checks.count == 2 && m.checkAfterCancel)
        guard case .badPassword = m.unlockCheckOutcome else {
            Issue.record("the failed check waits for the screen")
            return
        }
        m.consumeCheckAfterCancel()
        #expect(!m.checkAfterCancel)
    }

    /// Without the check's time no status can end the notice: an old present_recorded_at must not.
    @Test func thePresenceNoticeStaysWithoutTheChecksTime() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T12:00:00Z","interval_seconds":86400,"hold":true}"#
        ops.presentRecorded = false
        ops.answerDeadline = nil
        ops.presentRecordedAt = "2026-10-01T12:00:00Z"
        let m = manager(ops)
        _ = try await m.check(pin: "975310", password: "pw")
        #expect(m.presenceUnrecorded)
        try await m.refreshOwnerCheck()
        #expect(m.presenceUnrecorded)
    }

    /// Every status read hands its recovery on (the clock of a counter that stays unavailable).
    @Test func everyStatusReadReportsTheRecovery() async throws {
        let seen = SeenCounters()
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"ok","deadline":"2026-10-07T12:00:00Z","interval_seconds":86400,"hold":true}"#
        ops.counter = "unavailable"
        let m = manager(ops) { r, _ in seen.values.append(r?.counter) }
        try await m.refreshOwnerCheck()
        ops.counter = "ok"
        try await m.refreshOwnerCheck()
        #expect(seen.values == ["unavailable", "ok"])
    }

    @MainActor
    final class SeenCounters {
        var values: [String?] = []
    }

    /// A wipe forgets everything, also on the phone.
    @Test func clearForgetsEverything() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":4}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        m.onEvent(event("vault.locking", #"{"reason":"owner_check"}"#))
        m.clear()
        #expect(m.ownerCheck == nil && !m.lockedByOwnerCheck)
        #expect(manager(FakeOwnerCheckOps()).ownerCheck == nil)
    }

    /// What the phone kept is read only when asked (after the first-run cleanup and a pending wipe); a locked iPhone
    /// reads nothing and the next call reads it.
    @Test func theKeptStateIsReadLazilyAndAgainOnceTheIPhoneIsUnlocked() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":4}"#
        try await manager(ops).refreshOwnerCheck()
        let locked = Flag()
        let stored = stored
        let m = OwnerCheckManager(ops: { ops }, load: {
            if locked.on { throw KeysError.unavailable("owner check") }
            return stored.bytes
        }, persist: { _ in })
        #expect(m.ownerCheck == nil, "nothing read at construction")
        locked.on = true
        m.loadIfNeeded()
        #expect(m.ownerCheck == nil)
        locked.on = false
        m.loadIfNeeded()
        #expect(m.ownerCheck?.failures == 4)
    }

    @MainActor
    final class Flag {
        var on = false
    }

    /// An answer that arrives after a wipe cleared the state is not kept (nothing of the old vault comes back).
    @Test func anAnswerAfterAClearIsNotKept() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400}"#
        let gate = Gate()
        let m = OwnerCheckManager(ops: {
            await gate.wait()
            return ops
        }, load: { nil }, persist: { _ in })
        let read = Task { try await m.refreshOwnerCheck() }
        await Task.yield()
        m.clear()
        gate.open()
        try await read.value
        #expect(m.ownerCheck == nil)
    }

    @MainActor
    final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// Another device's check passed (`sync.event{owner_check}`): the gate opens here too.
    @Test func anotherDevicesCheckOpensTheGate() async throws {
        let ops = FakeOwnerCheckOps()
        ops.status = #"{"state":"held","deadline":"2026-10-06T11:00:00Z","interval_seconds":86400,"failures":2}"#
        let m = manager(ops)
        try await m.refreshOwnerCheck()
        m.onEvent(event("sync.event", #"{"kind":"owner_check","deadline":"2026-10-07T13:00:00Z"}"#))
        #expect(m.ownerCheck?.gated(now) == false && m.ownerCheck?.failures == 0)
    }
}

// swiftlint:enable line_length
