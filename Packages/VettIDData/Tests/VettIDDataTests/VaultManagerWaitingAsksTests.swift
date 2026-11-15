import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

/// (Owner decisions of 2026-11-15; ANDROID-PLAN 0.1.132 Notifications 7, IOS-PLAN §6.7) The asks still waiting when a
/// passed check, this phone's own or another device's, ends the held or due state in an open session, arrive once (``FeedManager/onArrival``, the
/// notifications' source) after the feed's full read and the approvals' read; nothing else is replayed, an expired ask is
/// not, and an unlock replays nothing.
@MainActor
@Suite(.serialized) struct VaultManagerWaitingAsksTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"
    /// The arrivals, as `kind:ref`.
    let arrived = Arrivals()

    @MainActor final class Arrivals {
        var all: [String] = []
    }

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
        let arrived = arrived
        m.feed.onArrival = { arrived.all.append("\($0.kind):\($0.ref ?? "")") }
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
        #expect(arrived.all.isEmpty, "nothing while held")
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { arrived.all == expected }, "\(arrived.all)")
        try await settled()
        #expect(arrived.all == expected, "once")
        #expect(m.feed.items.contains { $0.kind == "message.received" }, "listed, not notified")
    }

    @Test func anotherDevicesCheckNotifiesEachAskStillWaitingOnce() async throws {
        defer { phone.close() }
        let id = try await connected()
        m.onEvent(VaultManagerActivityTests.held())
        #expect(m.ownerChecks.ownerCheck?.state != .ok)
        let expected = try asksWhileHeld(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(arrived.all.isEmpty, "nothing while held")
        try service.otherDevicePassesCheck()
        #expect(await eventually { m.ownerChecks.ownerCheck?.state == .ok })
        #expect(await eventually { arrived.all == expected }, "\(arrived.all)")
        try await settled()
        #expect(arrived.all == expected, "once")
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
        #expect(arrived.all.isEmpty, "\(arrived.all)")
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
        #expect(await eventually { arrived.all == expected }, "\(arrived.all)")
        try await settled()
        #expect(arrived.all == expected, "once")
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
        #expect(arrived.all.isEmpty, "the unlock replays nothing")
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { arrived.all == expected }, "\(arrived.all)")
        try await settled()
        #expect(arrived.all == expected, "once")
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
        #expect(arrived.all.isEmpty, "the unlock replays nothing")
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        #expect(await eventually { arrived.all == expected }, "\(arrived.all)")
        try await settled()
        #expect(arrived.all == expected, "once")
    }

    /// A check passed while the vault was not held ends no hold: nothing is replayed.
    @Test func aCheckWithoutAHoldReplaysNothing() async throws {
        defer { phone.close() }
        let id = try await connected()
        let auth = try service.peerAsksAuthentication(id)
        #expect(await eventually { arrived.all == ["connection.authenticate.requested:\(auth)"] }, "the live arrival")
        #expect(try await m.ownerChecks.check(pin: pin, password: password) == .passed)
        try await settled()
        #expect(arrived.all == ["connection.authenticate.requested:\(auth)"])
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
        #expect(arrived.all.isEmpty, "\(arrived.all)")
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
        #expect(arrived.all.isEmpty, "\(arrived.all)")
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
        #expect(arrived.all.isEmpty, "\(arrived.all)")
    }
}
