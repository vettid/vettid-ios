import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// (Owner decisions of 2026-11-15; ANDROID-PLAN 0.1.132 Notifications 7, IOS-PLAN §6.7) The asks still waiting when a
/// passed check, this phone's own or another device's, ends the held or due state, are replayed once
/// (``FeedManager/onWaitingAsk``, taken as the app's notifier takes it) after the feed's full read and the approvals' read;
/// nothing else is replayed, an expired ask is not, and an unlock replays nothing.
@MainActor
@Suite(.serialized) struct VaultManagerWaitingAsksTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    /// The waiting asks replayed and the live arrivals, as `kind:ref`, taken as the app's notifier takes them.
    var replays: [String] { phone.notified.replays }
    var live: [String] { phone.notified.arrivals }

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }

    /// Enrolled and open, connected with another member, the feed read and its arrivals recorded; returns the connection id.
    func connected() async throws -> String {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        let r = try await m.connections.acceptInvite(try service.peerInvite(first: "Morgan", last: "Lee", name: "Mo"))
        #expect(await eventually { m.connections.requests.first?.sas != nil })
        try service.peerApproves(r.connectionID)
        try await m.approvals.approveOutgoing(r.connectionID)
        #expect(await eventually { m.connections.connections.map(\.id) == [r.connectionID] })
        #expect(await eventually { m.feed.load == .loaded })
        // The opening's read of every list is over before the arrivals are counted.
        await m.listsRead?.value
        phone.notified.arrivals = []
        phone.notified.replays = []
        return r.connectionID
    }

    /// While held or due: a sign-in still waiting, a sign-in that expires (gone from `pending.list`) and a message; with
    /// [devices] (only while due: the vault drops a desktop's session requests and held approvals when a hold begins), a
    /// held approval and a session request still waiting. Returns what should arrive after the check, in order.
    func asksWhileHeld(_ id: String, devices: Bool = false) throws -> [String] {
        let auth = try service.peerAsksAuthentication(id)
        var expected = ["connection.authenticate.requested:\(auth)"]
        if devices {
            let approval = try service.deviceAsksApproval()
            try service.feedItemArrives("approval.pending", ref: approval)
            let session = try service.deviceAsksSession(deviceID: "dev-3")
            try service.feedItemArrives("device.session.pending", ref: session)
            expected += ["approval.pending:\(approval)", "device.session.pending:\(session)"]
        }
        let expired = try service.peerAsksAuthentication(id)
        service.openAskGoes(expired)
        try service.feedItemArrives("message.received", connectionID: id)
        return expected
    }

    /// Nothing more arrives (no second replay) once every read is over.
    func settled() async throws {
        await m.listsRead?.value
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func thisPhonesOwnCheckNotifiesEachAskStillWaitingOnce() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.advanceVaultClock(86_401)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.state != .ok)
        let expected = try asksWhileHeld(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(replays.isEmpty && live.isEmpty, "nothing while held")
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { replays == expected }, "\(replays)")
        try await settled()
        #expect(replays == expected, "once")
        #expect(m.feed.items.contains { $0.kind == "message.received" }, "listed, not notified")
    }

    @Test func anotherDevicesCheckNotifiesEachAskStillWaitingOnce() async throws {
        defer { phone.close() }
        let id = try await connected()
        m.onEvent(VaultManagerActivityTests.held())
        #expect(m.ownerChecks.ownerCheck?.state != .ok)
        let expected = try asksWhileHeld(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(replays.isEmpty && live.isEmpty, "nothing while held")
        try service.otherDevicePassesCheck()
        #expect(await eventually { m.ownerChecks.ownerCheck?.state == .ok })
        #expect(await eventually { replays == expected }, "\(replays)")
        try await settled()
        #expect(replays == expected, "once")
    }

    /// A shortened interval moves the deadline earlier: the next passed check after a hold still replays.
    @Test func aShortenedIntervalStillReplays() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.advanceVaultClock(86_401)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        await m.listsRead?.value
        try await m.ownerChecks.setCheckInterval(seconds: 3_600)
        service.advanceVaultClock(3_601)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.state == .held)
        let expected = try asksWhileHeld(id)
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { replays == expected }, "\(replays)")
    }

    /// Due by the phone's clock alone (the vault last said ok), ended by another device's check: no hold ended and nothing
    /// else reads the lists, so the replay's own reads (the feed, then the approvals) bring the ask.
    @Test func aDueStateKnownByTheClockEndedElsewhereReplays() async throws {
        defer { phone.close() }
        let id = try await connected()
        try await m.ownerChecks.setCheckInterval(seconds: 3_600)
        await m.listsRead?.value
        phone.clockAhead = 3_601
        service.advanceVaultClock(3_601)
        #expect(m.ownerChecks.ownerCheck?.state == .ok && m.ownerChecks.ownerCheck?.gated(Date().addingTimeInterval(3_601)) == true)
        let auth = try service.peerAsksAuthentication(id, expiresIn: 7_200)
        try await Task.sleep(for: .milliseconds(100))
        #expect(replays.isEmpty && live.isEmpty, "nothing while due")
        let pagesBefore = service.pendingListPagesAnswered
        try service.otherDevicePassesCheck()
        #expect(await eventually { replays == ["connection.authenticate.requested:\(auth)"] }, "\(replays)")
        #expect(service.pendingListPagesAnswered > pagesBefore, "read by the replay's own reads")
        try await settled()
        #expect(replays.count == 1)
    }

    /// A `pending.list` read begun before the check does not count; one begun after it does.
    @Test func aReadBegunBeforeTheCheckDoesNotCount() async throws {
        defer { phone.close() }
        _ = try await connected()
        m.replayDue(.here, stateEnded: true)
        #expect(m.asksToNotify)
        m.openAsksRead(.merged([], stamp: m.asksFrom - 1))
        #expect(m.asksToNotify, "begun before: still waiting for its read")
        m.openAsksRead(.failed)
        #expect(m.asksToNotify, "a failed read: the next one")
        m.openAsksRead(.merged([], stamp: m.asksFrom))
        #expect(!m.asksToNotify)
    }

    /// The read's stamp is a count, not the clock: the phone's clock set back between the check and the read does not make
    /// the first read after the check look older than it.
    @Test func aClockSetBackBetweenTheCheckAndTheReadStillCounts() async throws {
        defer { phone.close() }
        _ = try await connected()
        m.replayDue(.here, stateEnded: true)
        #expect(m.asksToNotify)
        phone.clockAhead = -2 // a little, so that the session itself is not disturbed
        try await m.approvals.refreshApprovals(quietly: true, requests: false)
        #expect(!m.asksToNotify, "the read begun after the check counted")
    }

    /// A lock while the reads after the check are on their way: nothing is replayed, then or after the next unlock.
    @Test func aLockDuringTheReadsReplaysNothing() async throws {
        defer { phone.close() }
        let id = try await connected()
        // A read of every list on its way, which the end of the hold waits for.
        let opening = TestDeferred<Void>()
        m.listsReads += 1
        m.listsRead = Task { _ = try? await opening.value() }
        m.onEvent(VaultManagerActivityTests.held())
        _ = try asksWhileHeld(id)
        try service.otherDevicePassesCheck()
        #expect(await eventually { m.ownerChecks.ownerCheck?.state == .ok })
        #expect(m.asksToNotify)
        try await m.lock()
        #expect(!m.asksToNotify)
        opening.complete(())
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { m.feed.items.contains { $0.kind == "message.received" } })
        try await settled()
        #expect(replays.isEmpty, "\(replays)")
    }

    /// The due state (the hold off, VAULT-MESSAGING §3.6.7) ended by a passed check, as the held one.
    @Test func theDueStateEndedByACheckNotifiesEachAskStillWaitingOnce() async throws {
        defer { phone.close() }
        let id = try await connected()
        #expect(try await m.ownerChecks.check(pin: pin, password: password, holdOff: HoldOff(until: nil)) == .passed)
        await m.listsRead?.value
        service.advanceVaultClock(86_401)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.state == .due)
        let expected = try asksWhileHeld(id, devices: true)
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { replays == expected }, "\(replays)")
        try await settled()
        #expect(replays == expected, "once")
    }

    /// A lock during the hold, then an unlock with the PIN only that finds the vault held: the separate check that follows
    /// is not the unlock's, and replays (it needs nothing from before the hold).
    @Test func aSeparateCheckAfterAnUnlockReplays() async throws {
        defer { phone.close() }
        let id = try await connected()
        service.advanceVaultClock(86_401)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.state == .held)
        try await m.lock()
        let expected = try asksWhileHeld(id)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { m.phase == .unlocked && m.ownerChecks.ownerCheck?.state == .held })
        await m.listsRead?.value
        #expect(replays.isEmpty, "the unlock replays nothing")
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { replays == expected }, "\(replays)")
        try await settled()
        #expect(replays == expected, "once")
    }

    /// An unlock whose own check fails (a wrong password), then a separate passed check: that one replays.
    @Test func aPassedCheckAfterAnUnlocksFailedCheckReplays() async throws {
        defer { phone.close() }
        let id = try await connected()
        try await m.lock()
        service.advanceVaultClock(86_401)
        let expected = try asksWhileHeld(id)
        #expect(try await m.unlockWithCheck(pin: pin, password: "wrong horse") == .success)
        guard case .badPassword = m.ownerChecks.unlockCheckOutcome else {
            Issue.record("the unlock's check fails for its password")
            return
        }
        m.ownerChecks.consumeUnlockCheckOutcome()
        await m.listsRead?.value
        #expect(replays.isEmpty, "the unlock replays nothing")
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { replays == expected }, "\(replays)")
        try await settled()
        #expect(replays == expected, "once")
    }

    /// A check passed while the vault was not held ends no hold: nothing is replayed.
    @Test func aCheckWithoutAHoldReplaysNothing() async throws {
        defer { phone.close() }
        let id = try await connected()
        let auth = try service.peerAsksAuthentication(id)
        #expect(await eventually { live == ["connection.authenticate.requested:\(auth)"] }, "the live arrival")
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        try await settled()
        #expect(replays.isEmpty && live == ["connection.authenticate.requested:\(auth)"])
    }

    /// A vault without `pending.list` (`unsupported_type`, before 0.70.0) has no open asks to read: nothing is replayed.
    @Test func aVaultWithoutThePendingListReplaysNothing() async throws {
        defer { phone.close() }
        service.setPendingListSupported(false)
        let id = try await connected()
        service.advanceVaultClock(86_401)
        try await m.ownerChecks.refreshOwnerCheck()
        #expect(m.ownerChecks.ownerCheck?.state != .ok)
        _ = try asksWhileHeld(id)
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { m.feed.items.contains { $0.kind == "message.received" } })
        try await settled()
        #expect(replays.isEmpty, "\(replays)")
        #expect(!m.asksToNotify)
    }

    /// An unlock that also passes the check (a locked vault past its deadline) replays nothing: the vault opens after it.
    @Test func anUnlockThatPassesTheCheckReplaysNothing() async throws {
        defer { phone.close() }
        let id = try await connected()
        try await m.lock()
        service.advanceVaultClock(86_401)
        let auth = try service.peerAsksAuthentication(id)
        #expect(try await m.unlockWithCheck(pin: pin, password: password) == .success)
        #expect(m.ownerChecks.unlockCheckOutcome == .passed)
        #expect(await eventually { m.feed.items.contains { $0.ref == auth } })
        try await settled()
        #expect(replays.isEmpty, "\(replays)")
    }

    /// An ask that arrived while locked and is still waiting is listed after the unlock, not notified (as before).
    @Test func anUnlockReplaysNothing() async throws {
        defer { phone.close() }
        let id = try await connected()
        try await m.lock()
        let auth = try service.peerAsksAuthentication(id)
        #expect(try await m.unlock(pin: pin) == .success)
        #expect(await eventually { m.approvals.approvals.map(\.key).contains("auth:\(auth)") })
        #expect(await eventually { m.feed.items.contains { $0.ref == auth } })
        try await settled()
        #expect(replays.isEmpty, "\(replays)")
    }
}
