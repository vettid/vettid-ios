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
        #expect(await waitFor(seconds: 60) { m.listMarks[.requests] != nil }, "the requests were read as of a vault time")
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

    // MARK: what a re-read does not cover

    func old(_ type: String, _ body: String, id: String, by seconds: TimeInterval = 120) -> VaultMessage {
        VaultMessage(inner: Inner(id: id, type: type, ts: Date().addingTimeInterval(-seconds), body: Array(body.utf8)))
    }

    /// The inviter's decline is told only by the event: a held one redelivered after the re-read is still shown.
    @Test func aHeldDeclineRedeliveredAfterTheReReadIsStillShown() async throws {
        defer { phone.close() }
        try await heldBackground()
        m.onEvent(VaultMessage(inner: Inner(id: "k", type: "tag.changed", ts: Date(), body: Array("{}".utf8))))
        m.onForeground()
        #expect(await waitFor(seconds: 60) { m.listMarks[.requests] != nil })
        m.onEvent(VaultMessage(inner: Inner(
            id: "o1", type: "connection.request.outgoing", ts: Date().addingTimeInterval(30),
            body: Array(#"{"connection_id":"c1","sas":"111111","profile":{"first_name":"Morgan","last_name":"Lee"}}"#.utf8)
        )))
        m.onEvent(old("connection.event", #"{"connection_id":"c1","event":"failed","reason":"declined"}"#, id: "d1"))
        #expect(!m.connections.peerDeclines.isEmpty, "the notice is told")
    }

    /// A re-read that failed covers nothing: no mark is set, and the redelivered patch is applied, not ignored.
    @Test func aFailedReReadDoesNotSuppressTheRedeliveries() async throws {
        defer { phone.close() }
        try await heldBackground()
        service.refuse("connection.request.list", with: "retry", times: 20)
        m.onEvent(VaultMessage(inner: Inner(id: "k", type: "tag.changed", ts: Date(), body: Array("{}".utf8))))
        let reads = m.listsReads
        m.onForeground()
        #expect(await waitFor(seconds: 30) { m.listsReads > reads }, "the foreground's read began")
        await m.listsRead?.value
        #expect(m.listMarks[.requests] == nil, "the read did not answer: nothing is covered")
        m.onEvent(old("connection.request.pending", #"{"pending_id":"late","sas":"042817"}"#, id: "p1"))
        #expect(m.connections.requests.contains { $0.id == "late" }, "applied")
    }

    /// The foreground has read the lists with [refused] answering as given; the events [old] and [other] are of two lists.
    func readWith(refusing type: String, code: String) async throws {
        service.refuse(type, with: code, times: 20)
        try await heldBackground()
        m.onEvent(VaultMessage(inner: Inner(id: "k", type: "tag.changed", ts: Date(), body: Array("{}".utf8))))
        let reads = m.listsReads
        m.onForeground()
        #expect(await waitFor(seconds: 60) { m.listsReads > reads })
        await m.listsRead?.value
    }

    /// An event of [type] stamped just before the foreground's read (the vault's time of the read of the requests, whatever the load).
    func aged(_ type: String, id: String) -> VaultMessage {
        let read = m.listMarks[.requests]?.vault ?? Date()
        return VaultMessage(inner: Inner(id: id, type: type, ts: read.addingTimeInterval(-1), body: Array(#"{"pending_id":"x"}"#.utf8)))
    }

    /// A `pending.list` that failed covers no approval: its events, redelivered, are applied; the requests' read answered, so a
    /// request event is still covered.
    @Test func aFailedPendingListLeavesTheApprovalEventsApplied() async throws {
        defer { phone.close() }
        try await readWith(refusing: "pending.list", code: "retry")
        #expect(m.listMarks[.requests] != nil && m.listMarks[.approvals] == nil)
        #expect(!m.supersededByReread(aged("approval.pending", id: "a")), "no list answered: applied")
        #expect(m.supersededByReread(aged("connection.request.pending", id: "r")), "the requests answered: covered")
    }

    /// A list the vault does not have is no coverage either: a vault without `grant.list` gets its grant events applied.
    @Test func anUnsupportedGrantListLeavesTheGrantEventsApplied() async throws {
        defer { phone.close() }
        try await readWith(refusing: "grant.list", code: "unsupported_type")
        #expect(m.listMarks[.requests] != nil && m.listMarks[.grants] == nil)
        #expect(!m.supersededByReread(aged("grant.pending", id: "g")), "no grant list: applied")
    }

    /// The idempotent events and the ones told only by themselves are never covered by a read.
    @Test func idempotentEventsAreAlwaysApplied() async throws {
        defer { phone.close() }
        try await readWith(refusing: "grant.list", code: "unsupported_type")
        for type in ["message.new", "feed.event", "vote.event", "connection.event", "device.paired", "tag.changed"] {
            #expect(!m.supersededByReread(aged(type, id: type)), "\(type)")
        }
    }

    // MARK: the unlock window

    /// An alarm event that the order drops (an older one redelivered late) still closes the unlock window: an alarm always does.
    @Test func aDroppedAlarmEventStillClosesTheUnlockWindow() async throws {
        defer { phone.close() }
        try await openVault()
        m.onEvent(alarmEvent("a1", at: Date().addingTimeInterval(10)))
        m.unlockWindow = Date().addingTimeInterval(300)
        m.onEvent(alarmEvent("a0", at: Date().addingTimeInterval(-60)))
        #expect(m.alarm?.alarmID == "a1", "the older event is dropped")
        #expect(m.unlockWindow == nil, "and the window is closed all the same")
    }

    /// An alarm that a read shows (no event was heard) closes the window too.
    @Test func anAlarmReadClosesTheUnlockWindow() async throws {
        defer { phone.close() }
        try await openVault()
        m.unlockWindow = Date().addingTimeInterval(300)
        let started = m.beginAlarmRead()
        let info = CredentialInfo(
            exists: true, version: 1, key: nil, updatedAt: nil, alarm: CredentialAlarmInfo(alarmID: "a9", state: "frozen", at: nil)
        )
        m.finishAlarmRead(info, at: Date(), started: started)
        #expect(m.alarm?.alarmID == "a9" && m.unlockWindow == nil)
    }

    // MARK: marks as each list answers

    /// A redelivered request that arrives after the requests read answered, but before the other reads are over, is dropped: the
    /// mark is set where that read answers, not at the end of them all.
    @Test func aMarkIsSetAsItsOwnReadAnswersNotAtTheEnd() async throws {
        defer { phone.close() }
        try await openVault()
        var droppedWhileOthersRun = false
        var finished = false
        let at = Date()
        let itemsBefore = seen("item.list")
        m.refreshListsQuietly { [m] list in
            m.listMarks[list] = (at, Date().addingTimeInterval(120))
            guard list == .requests else { return }
            // Right after the requests answered: the feed, the conversations and the items are still to be read.
            let stale = VaultMessage(inner: Inner(
                id: "late", type: "connection.request.pending", ts: at.addingTimeInterval(-1),
                body: Array(#"{"pending_id":"late","sas":"042817"}"#.utf8)
            ))
            m.onEvent(stale)
            // The items are read last: not yet asked for when the requests answered.
            droppedWhileOthersRun = !finished && seen("item.list") == itemsBefore && !m.connections.requests.contains { $0.id == "late" }
        }
        await m.listsRead?.value
        finished = true
        #expect(droppedWhileOthersRun, "dropped between the requests' answer and the end of the other reads")
    }

    /// A requests read that was not applied (the requests were forgotten meanwhile) reports so: no mark.
    @Test func aRequestsReadThatWasNotAppliedIsNotCoverage() async throws {
        defer { phone.close() }
        try await openVault()
        let read = Task { @MainActor in try await m.connections.refreshRequests(quietly: true) }
        await Task.yield()
        m.connections.forgetOpenVault()
        let applied = try await read.value
        #expect(!applied, "forgotten while it was read: nothing was applied")
        let again = try await m.connections.refreshRequests(quietly: true)
        #expect(again, "a read that is applied says so")
    }

    // MARK: the presenter

    /// The read at the foreground answers without a presenter; the redelivered alarm event, dropped as older, still gives it.
    @Test func aDroppedAlarmEventStillGivesItsPresenter() async throws {
        defer { phone.close() }
        try await openVault()
        let started = m.beginAlarmRead()
        let info = CredentialInfo(
            exists: true, version: 1, key: nil, updatedAt: nil, alarm: CredentialAlarmInfo(alarmID: "a1", state: "frozen", at: nil)
        )
        m.finishAlarmRead(info, at: Date(), started: started)
        #expect(m.alarm?.alarmID == "a1" && m.alarm?.presenter == nil)
        let body = #"{"alarm_id":"a1","state":"frozen","presenter":"other"}"#
        m.onEvent(VaultMessage(inner: Inner(
            id: "e1", type: "credential.alarm", ts: Date().addingTimeInterval(-60), body: Array(body.utf8)
        )))
        #expect(m.alarm?.state == "frozen" && m.alarm?.presenter == "other", "the state follows the order; the presenter is the event's")
    }
}
