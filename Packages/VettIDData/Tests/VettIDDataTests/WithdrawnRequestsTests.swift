import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// The time the manager reads, moved by the tests (a batch is ordered by arrival).
@MainActor
final class WithdrawClock: @unchecked Sendable {
    nonisolated(unsafe) var now: Date
    init(_ now: Date) { self.now = now }
}

/// A challenge its challenger withdrew (VAULT-MESSAGING 0.80.0 §10.4 "Withdrawing a challenge"):
/// `sync.event{connection.authenticate.decided, approved: false, withdrawn: true}` closes the ask and is remembered; one ask
/// of a batch leaves the others; a feed item is read only once no ask of its batch is open; a flag for an ask not held reads
/// only an item that stands for no batch; an unflagged close is as before. Mirrors ANDROID-PLAN 0.1.101's tests.
@MainActor
@Suite struct WithdrawnRequestsTests {
    let ops = FakeApprovalOps()
    let connOps = FakeConnectionOps()
    let t0 = Date(timeIntervalSince1970: 1_791_115_200)
    let clock: WithdrawClock

    init() {
        ops.pendingSupported = true
        clock = WithdrawClock(t0)
    }

    func manager() -> ApprovalsManager {
        let ops = ops, connOps = connOps, clock = clock
        let c = ConnectionsManager(ops: { connOps }, now: { clock.now })
        return ApprovalsManager(connections: c, ops: { ops }, now: { clock.now })
    }

    func event(_ type: String, _ body: String, ts: Date? = nil) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: ts ?? clock.now, body: Array(body.utf8)))
    }

    var exp: String { Timestamps.formatMillis(t0.addingTimeInterval(3_600)) }

    func auth(_ id: String, conn: String = "c1") -> String { #"{"connection_id":"\#(conn)","request_id":"\#(id)","context":"Sign in","purpose":"signin","exp":"\#(exp)"}"# }

    /// An ask of [conn] arriving [seconds] after the start.
    func arrives(_ m: ApprovalsManager, _ id: String, conn: String = "c1", at seconds: TimeInterval) {
        clock.now = t0.addingTimeInterval(seconds)
        m.onEvent(event("connection.authenticate.pending", auth(id, conn: conn)))
    }

    func withdrawn(_ id: String, ts: Date? = nil) -> VaultMessage {
        event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"\#(id)","approved":false,"withdrawn":true}"#, ts: ts)
    }

    func decidedElsewhere(_ id: String) -> VaultMessage {
        event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"\#(id)","approved":true}"#)
    }

    func reads(_ m: ApprovalsManager) -> () -> [String] {
        var told: [String] = []
        m.onAskRead = { ref, onlySingle in told.append(onlySingle ? "\(ref):single" : ref) }
        return { told }
    }

    @Test func aWithdrawnAskClosesAndIsRemembered() {
        let m = manager()
        let told = reads(m)
        arrives(m, "a1", at: 0)
        #expect(m.approvals.map(\.key) == ["auth:a1"])
        m.onEvent(withdrawn("a1"))
        #expect(m.approvals.isEmpty && m.wasWithdrawn("auth:a1") && told() == ["a1"])
        // A late creation event does not bring it back.
        arrives(m, "a1", at: 5)
        #expect(m.approvals.isEmpty)
    }

    /// Without the flag (`approved: false` only) the ask closes as before and is not withdrawn.
    @Test func anUnflaggedCloseIsAsBefore() {
        let m = manager()
        let told = reads(m)
        arrives(m, "a1", at: 0)
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a1","approved":false}"#))
        arrives(m, "a2", at: 1)
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","request_id":"a2","approved":false,"withdrawn":false}"#))
        #expect(m.approvals.isEmpty && !m.wasWithdrawn("auth:a1") && !m.wasWithdrawn("auth:a2") && told().isEmpty)
    }

    /// A flag for a `request_id` this phone does not hold changes nothing it shows; only an item that stands for no batch is
    /// read (§10.4 "Closing"). A body without its `request_id` does nothing.
    @Test func aFlagForAnAskNotHeldReadsOnlyASingleItem() {
        let m = manager()
        let told = reads(m)
        arrives(m, "a1", at: 0)
        m.onEvent(withdrawn("zz"))
        m.onEvent(event("sync.event", #"{"kind":"connection.authenticate.decided","withdrawn":true}"#))
        #expect(m.approvals.map(\.key) == ["auth:a1"] && told() == ["zz:single"] && m.wasWithdrawn("auth:zz"))
    }

    /// The batch's first ask (whose item stands for the batch) is withdrawn while another is open: the item stays until
    /// the last ask of the batch closes, decided elsewhere or here; another connection's asks are not the batch.
    @Test func aBatchsItemIsReadWhenItsLastAskCloses() async throws {
        let m = manager()
        let told = reads(m)
        arrives(m, "a1", at: 0)
        arrives(m, "a2", at: 60)
        arrives(m, "b1", conn: "c2", at: 90)
        m.onEvent(withdrawn("a1"))
        #expect(Set(m.approvals.map(\.key)) == ["auth:a2", "auth:b1"] && told().isEmpty)
        m.onEvent(decidedElsewhere("a2"))
        #expect(told() == ["a1"])

        arrives(m, "a3", at: 1_000)
        arrives(m, "a4", at: 1_060)
        m.onEvent(withdrawn("a3"))
        try await m.denyAuthentication("a4")
        #expect(told() == ["a1", "a3"], "decided here")
    }

    /// A later ask of a batch (no item of its own) is withdrawn: nothing is read while the batch's first is open.
    @Test func aLaterAskOfABatchReadsNothing() {
        let m = manager()
        let told = reads(m)
        arrives(m, "a1", at: 0)
        arrives(m, "a2", at: 60)
        m.onEvent(withdrawn("a2"))
        #expect(m.approvals.map(\.key) == ["auth:a1"] && told().isEmpty)
    }

    /// Asks more than 10 minutes apart are two batches: withdrawing the first reads its own item at once.
    @Test func anotherBatchOfTheConnectionIsNotWaitedFor() {
        let m = manager()
        let told = reads(m)
        arrives(m, "a1", at: 0)
        arrives(m, "a2", at: 11 * 60)
        m.onEvent(withdrawn("a1"))
        #expect(m.approvals.map(\.key) == ["auth:a2"] && told() == ["a1"])
    }

    /// A list already read after the event judges the ask; the flag is noted all the same, for a screen still showing it.
    @Test func theFlagIsNotedAfterAListRead() async throws {
        let m = manager()
        ops.pendingAsks = [(kind: "authenticate", body: auth("a1"))]
        ops.pendingTs = t0.addingTimeInterval(30)
        try await m.refreshApprovals()
        #expect(m.approvals.map(\.key) == ["auth:a1"])
        m.onEvent(withdrawn("a1", ts: t0))
        #expect(m.wasWithdrawn("auth:a1") && m.approvals.map(\.key) == ["auth:a1"])
    }

    /// A withdrawal that arrives while `pending.list` is being read, the list read before it: the ask stays closed.
    @Test func aWithdrawalDuringAListReadStaysClosed() async throws {
        let m = manager()
        arrives(m, "a1", at: 0)
        ops.pendingAsks = [(kind: "authenticate", body: auth("a1"))]
        ops.pendingTs = t0.addingTimeInterval(10)
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let read = Task { try await m.refreshApprovals() }
        while ops.pendingCalls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        m.onEvent(withdrawn("a1", ts: t0.addingTimeInterval(20)))
        gate.complete(())
        try await read.value
        #expect(m.approvals.isEmpty && m.wasWithdrawn("auth:a1"))
    }

    /// The flags go with the vault's content at a lock or a hold.
    @Test func aForgetDropsTheFlags() {
        let m = manager()
        arrives(m, "a1", at: 0)
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

    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// An item by `ref`: a single one is read; a batch's only when asked for the whole batch; other items untouched.
    @Test func theFeedReadsTheItemAskedFor() async throws {
        let ops = FakeFeedOps()
        let single = ops.add("connection.authenticate.requested", at: t0, ref: "s1")
        let batch = ops.add("connection.authenticate.requested", at: t0, ref: "b1")
        let message = ops.add("message.received", at: t0, ref: "b1")
        for i in ops.items.indices where ops.items[i].itemID == batch.itemID { ops.items[i].count = 2 }
        let now = t0
        let f = FeedManager(ops: { ops }, gated: { false }, now: { now })
        try await f.refresh()
        f.markAskRead(ref: "s1", onlySingle: true)
        #expect(await eventually { f.items.first { $0.itemID == single.itemID }?.status == "read" })
        f.markAskRead(ref: "b1", onlySingle: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.items.first { $0.itemID == batch.itemID }?.status == "active", "a batch's item, for an ask not held")
        f.markAskRead(ref: "b1", onlySingle: false)
        #expect(await eventually { f.items.first { $0.itemID == batch.itemID }?.status == "read" })
        #expect(f.items.first { $0.itemID == message.itemID }?.status == "active", "not an ask's item")
    }
}

// swiftlint:enable line_length
