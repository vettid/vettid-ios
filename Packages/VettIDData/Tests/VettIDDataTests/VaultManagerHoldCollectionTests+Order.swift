import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

/// The order of a held background's events and the background's own work (see ``VaultManagerHoldCollectionTests``).
extension VaultManagerHoldCollectionTests {
    // MARK: the alarm's order, by the vault's clock

    func alarmEvent(_ id: String, at ts: Date) -> VaultMessage {
        VaultMessage(inner: Inner(id: "a\(id)\(ts.timeIntervalSince1970)", type: "credential.alarm", ts: ts, body: Array(alarm(id).utf8)))
    }

    /// A read that fails changes nothing of the order: the held alarm redelivered after it still shows.
    @Test func aFailedAlarmReadDoesNotDropTheHeldAlarm() async throws {
        defer { phone.close() }
        try await openVault()
        _ = m.beginAlarmRead() // the read fails: it never finishes
        m.onEvent(alarmEvent("a1", at: Date().addingTimeInterval(-60)))
        #expect(m.alarm?.alarmID == "a1", "the older held alarm is applied")
    }

    /// The order is vault time against vault time: a phone clock an hour fast still applies a fresh alarm, and an event the read's
    /// answer covers is dropped.
    @Test func aFastPhoneClockStillAppliesAFreshAlarm() async throws {
        defer { phone.close() }
        try await openVault()
        phone.clockAhead = 3600
        let started = m.beginAlarmRead()
        let answer = Date()
        m.finishAlarmRead(CredentialInfo(exists: true, version: 1, key: nil, updatedAt: nil, alarm: nil), at: answer, started: started)
        m.onEvent(alarmEvent("old", at: answer.addingTimeInterval(-10)))
        #expect(m.alarm == nil, "covered by the answer: dropped")
        m.onEvent(alarmEvent("fresh", at: answer.addingTimeInterval(1)))
        #expect(m.alarm?.alarmID == "fresh", "a fresh alarm is applied whatever the phone's clock says")
    }

    // MARK: the hold and the background's work

    /// A call that goes live during the work of leaving the foreground holds the collection too.
    @Test func aCallThatGoesLiveDuringTheBackgroundWorkIsHeld() async throws {
        defer { phone.close() }
        try await openVault()
        var asked = 0
        m.holdCollection {
            asked += 1
            return asked > 1
        }
        await m.onBackground(budget: .seconds(2))
        #expect(m.session != nil && m.heldBackground != nil && m.inBackground)
    }

    /// A held background counts as one background for the settlement windows, when it begins, and not again when it ends.
    @Test func aHeldBackgroundCountsOnce() async throws {
        defer { phone.close() }
        try await openVault()
        let before = m.moveFlags.book.backgrounds
        let live = Hold(true)
        m.holdCollection { live.on }
        await m.onBackground(budget: .seconds(2))
        #expect(m.moveFlags.book.backgrounds == before + 1)
        live.on = false
        m.collectionHoldEnded()
        #expect(m.moveFlags.book.backgrounds == before + 1, "not counted twice")
    }

    /// Overlapping leavings of the foreground each have their own work: the count returns to none.
    @Test func overlappingBackgroundsLeaveNoWorkBehind() async throws {
        defer { phone.close() }
        try await openVault()
        m.holdCollection { true }
        async let first: Void = m.onBackground(budget: .seconds(2))
        async let second: Void = m.onBackground(budget: .seconds(2))
        _ = await (first, second)
        #expect(m.backgroundWorks == 0)
    }

    // MARK: lists end on the newest state

    /// A request event that comes back from the relay after the foreground's read of the lists (it was held, then redelivered) is not
    /// applied: the read covers it, and it would put back a request a newer event or decision had ended.
    @Test func aRedeliveredRequestEventDoesNotPutBackWhatTheReadCovers() async throws {
        defer { phone.close() }
        try await heldBackground()
        // Something was kept: the foreground reads the lists again.
        m.onEvent(VaultMessage(inner: Inner(id: "k", type: "tag.changed", ts: Date(), body: Array("{}".utf8))))
        m.onForeground()
        #expect(await waitFor { m.listsReadAt != nil }, "the lists were read as of a vault time")
        let stale = VaultMessage(inner: Inner(
            id: "s1", type: "connection.request.pending", ts: Date().addingTimeInterval(-120),
            body: Array(#"{"pending_id":"gone","sas":"042817"}"#.utf8)
        ))
        m.onEvent(stale)
        #expect(!m.connections.requests.contains { $0.id == "gone" }, "older than the read: not applied")
        let fresh = VaultMessage(inner: Inner(
            id: "s2", type: "connection.request.pending", ts: Date().addingTimeInterval(30),
            body: Array(#"{"pending_id":"new","sas":"042817"}"#.utf8)
        ))
        m.onEvent(fresh)
        #expect(m.connections.requests.contains { $0.id == "new" }, "newer than the read: applied")
    }
}
