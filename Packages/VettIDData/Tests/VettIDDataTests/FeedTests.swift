import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault calls of ``FeedManager``: the feed in memory, as vettid-vault's `features/feed` keeps it.
final class FakeFeedOps: FeedOps, @unchecked Sendable {
    var items: [FeedItem] = []
    var seq: Int64 = 0
    var retention: Int?
    var calls: [String] = []
    var failing: Set<String> = []
    var listGate: TestDeferred<Void>?

    func feedList(afterSeq: Int64, limit: Int) async throws -> FeedPage {
        calls.append("list:\(afterSeq)")
        // Answered as the feed is now, delivered once the gate opens.
        let sel = items.filter { $0.seq > afterSeq }.sorted { $0.seq < $1.seq }
        let page = FeedPage(items: Array(sel.prefix(limit)), seq: seq)
        if let g = listGate { try await g.value() }
        if failing.contains("list") { throw VaultOpError(type: "feed.list", code: "retry", detail: "", body: nil) }
        return page
    }

    func feedUpdate(_ itemID: String, status: String) async throws -> FeedItem {
        calls.append("update:\(itemID):\(status)")
        if failing.contains("update") { throw VaultOpError(type: "feed.update", code: "retry", detail: "", body: nil) }
        guard let i = items.firstIndex(where: { $0.itemID == itemID }) else { throw VaultOpError(type: "feed.update", code: "not_found", detail: "", body: nil) }
        seq += 1
        items[i].status = status
        items[i].seq = seq
        return items[i]
    }

    func feedDelete(_ itemID: String) async throws {
        calls.append("delete:\(itemID)")
        guard let i = items.firstIndex(where: { $0.itemID == itemID }) else { return }
        seq += 1
        items[i].status = "deleted"
        items[i].seq = seq
    }

    func feedRetentionDays() async throws -> Int? { retention }

    /// A new item of the vault; returns it (what `feed.event` carries).
    @discardableResult
    func add(_ kind: String, at: Date, priority: String = "normal", ref: String? = nil, status: String = "active") -> FeedItem {
        seq += 1
        let item = FeedItem(itemID: String(format: "01JFEED%019d", seq), seq: seq, kind: kind, at: Timestamps.formatMillis(at), status: status, priority: priority, ref: ref)
        items.append(item)
        return item
    }
}

/// The feed in the app (VAULT-MESSAGING §10.9, ANDROID-PLAN §4 Notifications): the full read and the catch-up by `seq`,
/// live events, the member's changes, retention, the hold, and the kinds' classification and targets. Mirrors
/// vettid-android `FeedManagerTest`.
@MainActor
@Suite struct FeedTests {
    let ops = FakeFeedOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)

    func manager(gated: @escaping @MainActor () -> Bool = { false }) -> FeedManager {
        let ops = ops, now = now
        return FeedManager(ops: { ops }, gated: gated, now: { now })
    }

    func event(_ item: FeedItem) -> VaultMessage {
        var b = JsonBuilder().string("item_id", item.itemID).uint("seq", UInt64(item.seq)).string("kind", item.kind).string("at", item.at).string("status", item.status).string("priority", item.priority)
        if let r = item.ref { b = b.string("ref", r) }
        return VaultMessage(inner: Inner(id: Ulid.new(), type: "feed.event", ts: now, body: b.bytes()))
    }

    func sync(_ kind: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: "sync.event", ts: now, body: Array(#"{"kind":"\#(kind)"}"#.utf8)))
    }

    @Test func aFullReadIsPagedNewestFirstWithoutDeletedOrExpiredItems() async throws {
        for n in 0..<620 { ops.add("message.received", at: now.addingTimeInterval(Double(-n))) }
        ops.add("guide", at: now, status: "deleted")
        ops.add("connection.added", at: now.addingTimeInterval(-40 * 86_400))
        let f = manager()
        try await f.refresh()
        #expect(ops.calls.filter { $0.hasPrefix("list") } == ["list:0", "list:500"])
        #expect(f.items.count == 620 && f.load == .loaded && f.cursor == ops.seq)
        #expect(f.items.first?.at == Timestamps.formatMillis(now), "newest first by at")
        #expect(f.badge == FeedBadge(unread: 620, urgent: false))
    }

    @Test func liveItemsInOrderAndAGapCatchesUp() async throws {
        ops.add("message.received", at: now)
        let f = manager()
        var arrived: [String] = []
        f.onArrival = { arrived.append($0.kind) }
        try await f.refresh()
        let next = ops.add("credential.alarm", at: now, priority: "urgent")
        f.onEvent(event(next))
        #expect(f.items.count == 2 && f.badge.urgent && arrived == ["credential.alarm"])
        #expect(ops.calls == ["list:0"], "in order: no read")

        ops.add("grant.request", at: now, ref: "r1")
        let after = ops.add("connection.added", at: now)
        f.onEvent(event(after))
        #expect(await eventually { f.items.count == 4 })
        #expect(ops.calls.last == "list:2" && f.cursor == 4)
        #expect(arrived.sorted() == ["connection.added", "credential.alarm", "grant.request"])
    }

    /// An item that arrives while the full read is under way is read after it.
    @Test func anItemDuringTheFullReadIsNotLost() async throws {
        let f = manager()
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let read = Task { try await f.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        let item = ops.add("message.received", at: now)
        f.onEvent(event(item))
        ops.listGate = nil
        gate.complete(())
        try await read.value
        #expect(await eventually { f.items.map(\.itemID) == [item.itemID] })
    }

    @Test func anotherDevicesChangeIsReadAfterTheCursor() async throws {
        let item = ops.add("message.received", at: now)
        let f = manager()
        try await f.refresh()
        _ = try await ops.feedUpdate(item.itemID, status: "archived")
        ops.calls.removeAll()
        f.onEvent(sync("feed.updated"))
        #expect(await eventually { f.items.first?.status == "archived" })
        #expect(ops.calls == ["list:1"] && f.badge.unread == 0)
        _ = try await ops.feedDelete(item.itemID)
        f.onEvent(sync("feed.deleted"))
        #expect(await eventually { f.items.isEmpty })
    }

    @Test func aStatusChangeIsShownAtOnceAndUndoneWhenRefused() async throws {
        let item = ops.add("message.received", at: now)
        let f = manager()
        try await f.refresh()
        ops.failing = ["update"]
        await #expect(throws: VaultFailure.self) { try await f.setStatus(item.itemID, status: "read") }
        #expect(f.items.first?.status == "active")
        ops.failing = []
        try await f.setStatus(item.itemID, status: "read")
        #expect(f.items.first?.status == "read" && f.items.first?.seq == 2 && f.cursor == 2)
        await #expect(throws: VaultFailure.self) { try await f.setStatus(item.itemID, status: "deleted") }
    }

    @Test func viewingMarksReadButNotUrgentAndMarkAllReadDoes() async throws {
        let a = ops.add("message.received", at: now)
        let b = ops.add("owner_check.locked", at: now, priority: "urgent")
        let c = ops.add("grant.request", at: now, ref: "r1")
        let f = manager()
        try await f.refresh()
        f.markViewed([a.itemID, b.itemID])
        #expect(await eventually { f.items.first { $0.itemID == a.itemID }?.status == "read" })
        #expect(f.badge == FeedBadge(unread: 2, urgent: true))
        f.markReadWhere(kinds: ["grant.request"], ref: "r1")
        #expect(await eventually { f.items.first { $0.itemID == c.itemID }?.status == "read" })
        try await f.markAllRead()
        #expect(f.badge == FeedBadge())
        try await f.delete(b.itemID)
        #expect(f.items.count == 2 && ops.calls.contains("delete:\(b.itemID)"))
    }

    @Test func retentionFromTheSettings() async throws {
        ops.retention = 7
        ops.add("message.received", at: now.addingTimeInterval(-8 * 86_400))
        ops.add("message.received", at: now.addingTimeInterval(-6 * 86_400))
        let f = manager()
        try await f.refresh()
        #expect(f.items.count == 1)
    }

    @Test func heldNothingIsTakenAndClearDropsAReadUnderWay() async throws {
        var held = false
        ops.add("message.received", at: now)
        let f = manager(gated: { held })
        try await f.refresh()
        held = true
        f.onEvent(event(ops.add("credential.alarm", at: now, priority: "urgent")))
        f.onEvent(sync("feed.updated"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.items.count == 1 && ops.calls == ["list:0"])

        held = false
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let read = Task { try await f.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        f.clear()
        gate.complete(())
        try await read.value
        #expect(f.items.isEmpty && f.load == .notLoaded, "a read from before the lock is not shown")
    }

    /// IOS-PLAN §4.1 (de-duplication): one recovery raises one notification, `recovery.completed`; `credential.recovered`,
    /// `recovery.device_paired` and a PIN change are neither listed, counted nor arrivals, and the cursor moves past them.
    @Test func theHistoryOnlyKindsAreNeitherListedCountedNorArrivals() async throws {
        ops.add("vault.pin_changed", at: now)
        ops.add("message.received", at: now)
        let f = manager()
        var arrived: [String] = []
        f.onArrival = { arrived.append($0.kind) }
        try await f.refresh()
        #expect(f.items.map(\.kind) == ["message.received"] && f.badge.unread == 1)
        for kind in ["credential.recovered", "recovery.device_paired", "recovery.completed"] {
            f.onEvent(event(ops.add(kind, at: now)))
        }
        #expect(f.cursor == 5 && ops.calls == ["list:0"], "in order: no catch-up")
        #expect(arrived == ["recovery.completed"])
        #expect(Set(f.items.map(\.kind)) == ["message.received", "recovery.completed"] && f.badge.unread == 2)
        // Nor from a catch-up.
        ops.add("vault.pin_changed", at: now)
        f.onEvent(sync("feed.updated"))
        #expect(await eventually { f.cursor == 6 })
        #expect(arrived == ["recovery.completed"] && f.items.count == 2)
        // A closure item that is not a rollback is hidden too; a rollback is listed and arrives.
        f.onEvent(event(ops.add("recovery.generation_closed", at: now, priority: "urgent", ref: "4/stale")))
        f.onEvent(event(ops.add("recovery.generation_closed", at: now, priority: "urgent", ref: "5/rollback")))
        #expect(arrived == ["recovery.completed", "recovery.generation_closed"] && f.items.count == 3 && f.badge.urgent)
    }

    @Test func kindsTargetsAndAsks() throws {
        let item = { (kind: String, conn: String?, ref: String?) in FeedItem(itemID: "i", seq: 1, kind: kind, at: "", status: "active", connectionID: conn, ref: ref) }
        #expect(FeedKinds.classify("grant.request") == .shown && FeedKinds.classify("leash.item.run") == .later)
        #expect(FeedKinds.classify("wallet.signed") == .later && FeedKinds.classify("future.kind") == .unknown)
        #expect(FeedKinds.target(item("grant.request", "c1", "r1")) == .approval(key: "grant:r1"))
        #expect(FeedKinds.target(item("approval.pending", nil, "a1")) == .approval(key: "device:approval.pending:a1"))
        #expect(FeedKinds.target(item("connection.request.peer_declined", nil, "p1")) == .connections)
        #expect(FeedKinds.target(item("message.received", "c1", "m1")) == .conversation("c1"))
        #expect(FeedKinds.target(item("share.rate_limited", "c1", "rule")) == .shareRule(connectionID: "c1", ruleID: "rule"))
        #expect(FeedKinds.target(item("item.revealed", nil, nil)) == .sheet && FeedKinds.target(item("owner_check.locked", nil, nil)) == .security)
        #expect(FeedKinds.isAsk("critical-secret.use.request") && !FeedKinds.isAsk("message.received"))
        #expect(FeedAsks.of("device:device.session.pending:s1")?.kinds == ["device.session.pending"] && FeedAsks.of("device:device.session.pending:s1")?.ref == "s1")
        #expect(FeedAsks.of("outgoing:c1") == nil && FeedAsks.of("auth:r1")?.kinds == ["connection.authenticate.requested"])
        #expect(FeedKinds.holdChange("off_until:2026-11-01T00:00:00.000Z") == .offUntil(OwnerCheckManager.instant("2026-11-01T00:00:00.000Z")))
        #expect(FeedKinds.holdChange("on:expired") == .backOn && FeedKinds.holdChange(nil) == .on)
        #expect(FeedKinds.signerChange("google_play:vettid")?.new == "vettid" && FeedKinds.signerChange("x") == nil)
        #expect(FeedKinds.classify("recovery.attempt") == .shown && FeedKinds.classify("recovery.generation_closed") == .shown)
        #expect(FeedKinds.target(item("recovery.attempt", nil, "2/3/not_success/counter")) == .sheet)
    }
}

// swiftlint:enable line_length
