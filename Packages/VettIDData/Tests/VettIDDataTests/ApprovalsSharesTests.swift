import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// The share decisions among the approvals (VAULT-MESSAGING §10.12): built from `share.pending.list` when the approvals are
/// read, joined to the events that carry what the list leaves out, one question per item and subject. Mirrors the share
/// parts of vettid-android `SocialManager`'s tests.
@MainActor
@Suite struct ApprovalsSharesTests {
    let ops = FakeApprovalOps()
    let connOps = FakeConnectionOps()
    let file = MemoryFile()
    let now = Date(timeIntervalSince1970: 1_791_115_200)

    func manager(names: [String: ShareItem] = [:]) -> ApprovalsManager {
        let ops = ops, connOps = connOps, file = file, now = now
        let c = ConnectionsManager(ops: { connOps }, now: { now })
        let m = ApprovalsManager(
            connections: c, ops: { ops }, load: { file.bytes }, persist: { file.bytes = $0.isEmpty ? nil : $0 }, now: { now },
            itemNames: { names }
        )
        m.loadIfNeeded()
        return m
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    func share(_ m: ApprovalsManager, _ rule: String) -> ShareDecision? {
        for case .share(let s) in m.approvals where s.ruleID == rule { return s }
        return nil
    }

    static let rules = #"{"rules":[{"rule_id":"r1","subject":{"connection_id":"c1"},"tags":["medical"]},{"rule_id":"r2","subject":{"connection_id":"c1"},"tags":["insurance"],"mode":"auto"}]}"#

    @Test func theListBuildsTheDecisionsWithTheRulesTags() async throws {
        ops.pendingPages = [#"{"pending":[{"rule_id":"r1","subject":{"connection_id":"c1"},"item_id":"i1","name":"Allergies","category":"medical","sensitivity":"data","at":"2026-10-08T10:00:00.000Z"}]}"#]
        ops.rulePages = [Self.rules]
        let m = manager()
        try await m.refreshApprovals()
        let s = try #require(share(m, "r1"))
        #expect(s.items.map(\.name) == ["Allergies"] && s.tags == ["medical"] && s.rules.map(\.ruleID) == ["r1", "r2"] && s.rule?.mode == .ask)
        #expect(ops.shareCalls == ["pending:nil:500", "rules:nil"])
        // Read only: nothing is kept in the file for a decision the list builds.
        #expect(file.bytes == nil)
    }

    @Test func anEventsItemsAreWhatTheListSaysIsStillPending() async throws {
        let m = manager()
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"i1","name":"A","category":"other","sensitivity":"data"},{"item_id":"i2","name":"B","category":"other","sensitivity":"data"}],"reason":"rule"}"#))
        // Another device decided i1: the list has i2 only, unnamed there, and says another rule asks.
        ops.pendingPages = [#"{"pending":[{"rule_id":"r1","subject":{"connection_id":"c1"},"item_id":"i2","name":"","category":"other","sensitivity":"data","ask_rule_id":"r0"}]}"#]
        ops.rulePages = [Self.rules]
        try await m.refreshApprovals()
        let s = try #require(share(m, "r1"))
        #expect(s.items.map(\.itemID) == ["i2"] && s.items[0].name == "B" && s.items[0].askRuleID == "r0")
        #expect(s.tags == ["medical"] && s.reason == "rule", "the event's reason, the list's tags")
    }

    @Test func aDecisionTheListNoLongerHasLeavesWithItsEvent() async throws {
        let m = manager()
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"i1","name":"A","category":"other","sensitivity":"data"}]}"#))
        ops.pendingPages = [#"{"pending":[]}"#]
        ops.rulePages = [Self.rules]
        try await m.refreshApprovals()
        #expect(m.approvals.isEmpty)
        #expect(manager().approvals.isEmpty, "gone from the file too")
    }

    @Test func aListThatCannotBeReadDropsNothing() async throws {
        let m = manager()
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"i1","name":"A","category":"other","sensitivity":"data"}]}"#))
        try await m.refreshApprovals()
        #expect(share(m, "r1")?.items.map(\.itemID) == ["i1"] && manager().approvals.count == 1)
        #expect(ops.shareCalls == ["pending:nil:500", "rules:nil"], "the older form was tried, and failed too")
    }

    @Test func aVaultBefore021ListsTheRulesPendingIds() async throws {
        ops.rulePages = [#"{"rules":[{"rule_id":"r1","subject":{"connection_id":"c1"},"tags":["medical"],"pending":["i1","i7"],"updated_at":"2026-10-08T10:00:00.000Z"}]}"#]
        let m = manager(names: ["i1": ShareItem(itemID: "i1", name: "Allergies", category: "medical", sensitivity: "data")])
        try await m.refreshApprovals()
        let s = try #require(share(m, "r1"))
        #expect(s.items.map(\.name) == ["Allergies", ""] && s.items.map(\.category) == ["medical", "other"] && s.tags == ["medical"])
        #expect(s.receivedAt == OwnerCheckManager.instant("2026-10-08T10:00:00Z"))
    }

    @Test func oneQuestionPerItemAndSubject() async throws {
        ops.pendingPages = [#"{"pending":[{"rule_id":"r1","subject":{"connection_id":"c1"},"item_id":"i1","name":"A","category":"other","sensitivity":"data"},{"rule_id":"r2","subject":{"connection_id":"c1"},"item_id":"i1","name":"A","category":"other","sensitivity":"data","ask_rule_id":"r1"},{"rule_id":"r2","subject":{"connection_id":"c1"},"item_id":"i2","name":"B","category":"other","sensitivity":"data"}]}"#]
        ops.rulePages = [Self.rules]
        let m = manager()
        try await m.refreshApprovals()
        #expect(share(m, "r1")?.items.map(\.itemID) == ["i1"] && share(m, "r1")?.items[0].alsoIn == ["r2"])
        #expect(share(m, "r2")?.items.map(\.itemID) == ["i2"])
    }
}

// swiftlint:enable line_length
