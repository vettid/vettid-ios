import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// A challenge its challenger withdrew (VAULT-MESSAGING 0.80.0 §10.4 "Withdrawing a challenge"):
/// `sync.event{connection.authenticate.decided, approved: false, withdrawn: true}` closes the ask and is remembered; one ask
/// of a batch leaves the others; the feed item is read only when no ask of its batch is open; an unflagged close is as
/// before. Mirrors ANDROID-PLAN 0.1.101's tests.
@MainActor
@Suite struct WithdrawnRequestsTests {
    let ops = FakeApprovalOps()
    let connOps = FakeConnectionOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)

    init() { ops.pendingSupported = true }

    func manager() -> ApprovalsManager {
        let ops = ops, connOps = connOps, now = now
        let c = ConnectionsManager(ops: { connOps }, now: { now })
        return ApprovalsManager(connections: c, ops: { ops }, now: { now })
    }

    func event(_ type: String, _ body: String, ts: Date? = nil) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: ts ?? now, body: Array(body.utf8)))
    }

    var exp: String { Timestamps.formatMillis(now.addingTimeInterval(600)) }

    func auth(_ id: String, conn: String = "c1") -> String { #"{"connection_id":"\#(conn)","request_id":"\#(id)","context":"Sign in","purpose":"signin","exp":"\#(exp)"}"# }

    func withdrawn(_ id: String, ts: Date? = nil) -> VaultMessage {
        event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"\#(id)","approved":false,"withdrawn":true}"#, ts: ts)
    }

    @Test func aWithdrawnAskClosesAndIsRemembered() {
        let m = manager()
        var told: [String] = []
        m.onWithdrawn = { ref, conn, others in told.append("\(ref):\(conn):\(others)") }
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        #expect(m.approvals.map(\.key) == ["auth:a1"])
        m.onEvent(withdrawn("a1"))
        #expect(m.approvals.isEmpty && m.wasWithdrawn("auth:a1") && told == ["a1:c1:false"])
        // A late creation event does not bring it back.
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        #expect(m.approvals.isEmpty)
    }

    /// Without the flag (`approved: false` only) the ask closes as before and is not withdrawn.
    @Test func anUnflaggedCloseIsAsBefore() {
        let m = manager()
        var told = 0
        m.onWithdrawn = { _, _, _ in told += 1 }
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a1","approved":false}"#))
        m.onEvent(event("connection.authenticate.pending", auth("a2")))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a2","approved":false,"withdrawn":false}"#))
        #expect(m.approvals.isEmpty && !m.wasWithdrawn("auth:a1") && !m.wasWithdrawn("auth:a2") && told == 0)
    }

    /// A flag for a `request_id` this phone does not hold changes nothing it shows, and tells the feed nothing.
    @Test func aFlagForAnUnknownAskDoesNothing() {
        let m = manager()
        var told = 0
        m.onWithdrawn = { _, _, _ in told += 1 }
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        m.onEvent(withdrawn("zz"))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","withdrawn":true}"#))
        #expect(m.approvals.map(\.key) == ["auth:a1"] && told == 0)
    }

    /// One ask of a batch is withdrawn: the others stay, and the feed is told another is open.
    @Test func oneAskOfABatchLeavesTheOthers() {
        let m = manager()
        var told: [Bool] = []
        m.onWithdrawn = { _, _, others in told.append(others) }
        for id in ["a1", "a2"] { m.onEvent(event("connection.authenticate.pending", auth(id))) }
        m.onEvent(event("connection.authenticate.pending", auth("b1", conn: "c2")))
        m.onEvent(withdrawn("a1"))
        #expect(Set(m.approvals.map(\.key)) == ["auth:a2", "auth:b1"] && told == [true])
        m.onEvent(withdrawn("a2"))
        #expect(m.approvals.map(\.key) == ["auth:b1"] && told == [true, false], "another connection's ask is not the batch's")
    }

    /// A list already read closes the ask; the flag is noted all the same, for a screen still showing it.
    @Test func theFlagIsNotedAfterAListRead() async throws {
        let m = manager()
        ops.pendingAsks = [(kind: "authenticate", body: auth("a1"))]
        ops.pendingTs = now.addingTimeInterval(30)
        try await m.refreshApprovals()
        #expect(m.approvals.map(\.key) == ["auth:a1"])
        m.onEvent(withdrawn("a1", ts: now))
        #expect(m.wasWithdrawn("auth:a1"))
    }

    /// The flags go with the vault's content at a lock or a hold.
    @Test func aForgetDropsTheFlags() {
        let m = manager()
        m.onEvent(event("connection.authenticate.pending", auth("a1")))
        m.onEvent(withdrawn("a1"))
        m.forgetOpenVault()
        #expect(!m.wasWithdrawn("auth:a1"))
    }

    /// A service connection is known by its `peer_kind` (VAULT-MESSAGING 0.69.0 §6.4), for the mute's confirmation.
    @Test func aServiceIsKnownByItsPeerKind() throws {
        func info(_ extra: String) throws -> ConnectionInfo {
            let o = try StrictJson.parseObject(#"{"id":"c1","state":"active","kind":"connection","name":"VettID Member Service"\#(extra)}"#)
            return ConnectionParser.connection(try #require(Connection.of(o)))
        }
        #expect(try info(#","peer_kind":"service""#).isService)
        #expect(try !info("").isService && !info(#","peer_kind":"person""#).isService && !info(#","peer_kind":7"#).isService)
    }

    // MARK: - The feed

    func feed(_ ops: FakeFeedOps) -> FeedManager {
        let now = now
        return FeedManager(ops: { ops }, gated: { false }, now: { now })
    }

    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A single ask's item is read; a batch's item stays while another of its asks is open, and is read once none is; another
    /// connection's items are not touched.
    @Test func theFeedItemIsReadWhenNoAskOfItsBatchIsOpen() async throws {
        let ops = FakeFeedOps()
        let single = ops.add("connection.authenticate.requested", at: now, ref: "s1")
        let batch = ops.add("connection.authenticate.requested", at: now, ref: "b1")
        let other = ops.add("connection.authenticate.requested", at: now, ref: "o1")
        let message = ops.add("message.received", at: now)
        for i in ops.items.indices {
            ops.items[i].connectionID = ops.items[i].itemID == other.itemID ? "c2" : "c1"
            if ops.items[i].itemID == batch.itemID { ops.items[i].count = 2 }
        }
        let f = feed(ops)
        try await f.refresh()
        f.askWithdrawn(ref: "s1", connectionID: "c1", othersOpen: true)
        #expect(await eventually { f.items.first { $0.itemID == single.itemID }?.status == "read" })
        f.askWithdrawn(ref: "b1", connectionID: "c1", othersOpen: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.items.first { $0.itemID == batch.itemID }?.status == "active", "a batch with an ask still open")
        // A later ask of the batch (no item of its own) is withdrawn and none is left.
        f.askWithdrawn(ref: "b2", connectionID: "c1", othersOpen: false)
        #expect(await eventually { f.items.first { $0.itemID == batch.itemID }?.status == "read" })
        #expect(f.items.first { $0.itemID == other.itemID }?.status == "active" && f.items.first { $0.itemID == message.itemID }?.status == "active")
    }
}

// swiftlint:enable line_length
