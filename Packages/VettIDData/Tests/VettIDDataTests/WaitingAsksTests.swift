import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// (Owner decisions of 2026-11-15; ANDROID-PLAN 0.1.132 Notifications 7, IOS-PLAN §6.7) After a passed check ends the held
/// or due state, each ask still waiting of exactly three kinds is notified once: a member authentication, a device
/// session, a held approval; never an expired, decided, read or unlisted one, a pairing or anything else. Mirrors
/// vettid-android `WaitingAsksTest`.
@MainActor
@Suite struct WaitingAsksTests {
    let now = Date(timeIntervalSince1970: 1_791_115_200)
    static let signIn = "connection.authenticate.requested", session = "device.session.pending", held = "approval.pending"

    func item(_ id: String, _ kind: String, ref: String? = nil, status: String = "active", seq: Int64 = 1) -> FeedItem {
        FeedItem(itemID: id, seq: seq, kind: kind, at: Timestamps.formatMillis(now.addingTimeInterval(-60)), status: status, ref: ref ?? "r\(id)")
    }

    func signIn(_ ref: String, exp: Date?) -> PendingApproval {
        .authentication(AuthenticationRequest(requestID: ref, connectionID: "c1", context: nil, receivedAt: now.addingTimeInterval(-60), exp: exp))
    }

    func device(_ kind: String, _ ref: String, exp: Date?) -> PendingApproval {
        .device(DeviceRequest(type: kind, id: ref, deviceName: nil, role: nil, requestType: nil, receivedAt: now.addingTimeInterval(-60), exp: exp))
    }

    func ids(_ items: [FeedItem], _ approvals: [PendingApproval]) -> [String] {
        WaitingAsks.of(items, approvals: approvals, now: now).map(\.itemID)
    }

    @Test func exactlyTheThreeKinds() {
        #expect(WaitingAsks.kinds == [Self.signIn, Self.session, Self.held])
    }

    @Test func eachKindStillWaiting() {
        let items = [item("1", Self.signIn, seq: 1), item("2", Self.session, seq: 2), item("3", Self.held, seq: 3)]
        let approvals = [
            signIn("r1", exp: now.addingTimeInterval(200)),
            device(Self.session, "r2", exp: now.addingTimeInterval(300)),
            device(Self.held, "r3", exp: now.addingTimeInterval(100)),
        ]
        #expect(ids(items, approvals) == ["1", "2", "3"])
    }

    @Test func anExpiredAskIsNotWaitingButOneWithoutExpIs() {
        let items = [item("1", Self.signIn), item("2", Self.held)]
        #expect(ids(items, [signIn("r1", exp: now.addingTimeInterval(-1)), device(Self.held, "r2", exp: nil)]) == ["2"])
        #expect(ids(items, [signIn("r1", exp: now)]).isEmpty, "exp at now: passed")
    }

    @Test func anAskNoLongerListedIsNotWaiting() {
        let items = [item("1", Self.signIn), item("2", Self.session), item("3", Self.held)]
        // Decided or gone: not listed; a listed ask of another kind with the same ref does not count.
        #expect(ids(items, [device(Self.held, "r1", exp: nil), signIn("r2", exp: nil)]).isEmpty)
    }

    @Test func aReadArchivedOrDeletedItemIsNotReplayed() {
        let items = [
            item("1", Self.held, status: FeedManager.statusRead), // read in Notifications, not decided
            item("2", Self.held, status: FeedManager.statusArchived),
            item("3", Self.held, status: FeedManager.statusDeleted),
        ]
        #expect(ids(items, ["r1", "r2", "r3"].map { device(Self.held, $0, exp: nil) }).isEmpty)
    }

    /// A listed pairing and a listed grant request are still left out: the filter is the three kinds and no other.
    @Test func aListedPairingOrGrantIsLeftOut() {
        let items = [item("1", "device.pair.pending"), item("2", "grant.request"), item("3", Self.held)]
        let approvals: [PendingApproval] = [
            device("device.pair.pending", "r1", exp: nil),
            .grant(GrantRequest(requestID: "r2", connectionID: "c1", entries: [], uses: nil, expiresIn: nil, reason: nil, receivedAt: now, exp: nil)),
            device(Self.held, "r3", exp: nil),
        ]
        #expect(ids(items, approvals) == ["3"])
    }

    @Test func anItemWithoutARefMatchesNothing() {
        var none = item("2", Self.held)
        none.ref = nil
        #expect(ids([item("1", Self.signIn, ref: ""), none], [signIn("", exp: nil), device(Self.held, "", exp: nil)]).isEmpty)
    }

    @Test func anotherKindIsNeverReplayed() {
        let items = [item("1", "message.received"), item("2", "connection.request"), item("3", "grant.request"), item("4", "critical-secret.use.request")]
        let approvals: [PendingApproval] = [
            .grant(GrantRequest(requestID: "r3", connectionID: "c1", entries: [], uses: nil, expiresIn: nil, reason: nil, receivedAt: now, exp: nil)),
        ]
        #expect(ids(items, approvals).isEmpty)
    }

    @Test func inSeqOrder() {
        let items = [item("a", Self.session, seq: 7), item("b", Self.signIn, seq: 2), item("c", Self.held, seq: 5)]
        let approvals = [signIn("rb", exp: nil), device(Self.held, "rc", exp: nil), device(Self.session, "ra", exp: nil)]
        #expect(ids(items, approvals) == ["b", "c", "a"])
    }

    func feedEvent(_ i: FeedItem) -> VaultMessage {
        let b = JsonBuilder().string("item_id", i.itemID).uint("seq", UInt64(i.seq)).string("kind", i.kind).string("at", i.at).string("status", i.status).string("ref", i.ref ?? "")
        return VaultMessage(inner: Inner(id: Ulid.new(), type: "feed.event", ts: now, body: b.bytes()))
    }

    /// The replay waits for the feed's first full read after the check; the full read notifies nothing; each waiting ask
    /// arrives once as a waiting ask, not one that already arrived live since the check, and nothing without the window,
    /// while gated, or twice.
    @Test func theReplayMakesOnlyTheWaitingAsksArrive() async throws {
        let ops = FakeFeedOps()
        let t = now
        var gated = false
        let f = FeedManager(ops: { ops }, gated: { gated }, now: { t })
        var arrived: [String] = [], replayed: [String] = []
        f.onArrival = { arrived.append($0.itemID) }
        f.onWaitingAsk = { replayed.append($0.itemID) }
        let approvals = [signIn("r1", exp: now.addingTimeInterval(200)), signIn("r2", exp: now.addingTimeInterval(200))]
        let ask = ops.add(Self.signIn, at: now.addingTimeInterval(-60), ref: "r1")
        ops.add("message.received", at: now)
        try await f.refresh()
        f.replayWaitingAsks(approvals)
        #expect(arrived.isEmpty && replayed.isEmpty, "no window: no replay")

        f.clear()
        f.openWaitingAsks()
        f.replayWaitingAsks(approvals)
        #expect(replayed.isEmpty, "waits for the full read")
        try await f.refresh()
        #expect(arrived.isEmpty && replayed == [ask.itemID], "the full read notifies nothing; the replay once")
        f.replayWaitingAsks(approvals)
        #expect(replayed == [ask.itemID], "the window is closed")

        // An ask that arrives live after the check is notified then, not again by the replay.
        f.openWaitingAsks()
        let live = ops.add(Self.signIn, at: now, ref: "r2")
        f.onEvent(feedEvent(live))
        #expect(arrived == [live.itemID])
        try await f.refresh()
        f.replayWaitingAsks(approvals)
        #expect(replayed == [ask.itemID, ask.itemID], "a new check: once more, without the live one")

        // Held again before the replay: nothing; a clear closes the window.
        f.openWaitingAsks()
        try await f.refresh()
        gated = true
        f.replayWaitingAsks(approvals)
        gated = false
        f.openWaitingAsks()
        f.clear()
        try await f.refresh()
        f.replayWaitingAsks(approvals)
        #expect(replayed.count == 2)
    }
}

// swiftlint:enable line_length
