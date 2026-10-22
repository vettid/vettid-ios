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

    func entry(_ rule: String, _ item: String) -> String {
        #"{"rule_id":"\#(rule)","subject":{"connection_id":"c1"},"item_id":"\#(item)","name":"\#(item)","category":"other","sensitivity":"data"}"#
    }

    /// An item decided in one rule leaves the subject's other rules' questions too (§10.12 one answer per item and subject),
    /// also when another device decided it, and without a new read.
    @Test func aDecidedItemDoesNotComeBackUnderTheSubjectsOtherRule() async throws {
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "i1")),\#(entry("r1", "i2")),\#(entry("r2", "i1"))]}"#]
        ops.rulePages = [Self.rules]
        let m = manager()
        try await m.refreshApprovals()
        #expect(share(m, "r1")?.items.map(\.itemID) == ["i1", "i2"] && share(m, "r2") == nil)
        m.onEvent(event("sync.event", #"{"kind":"share.decided","rule_id":"r1","included":["i1"],"declined":[]}"#))
        #expect(share(m, "r1")?.items.map(\.itemID) == ["i2"] && share(m, "r2") == nil)
        m.onEvent(event("sync.event", #"{"kind":"share.decided","rule_id":"r1","included":[],"declined":["i2"]}"#))
        #expect(m.approvals.isEmpty)
        // Decided here: the same.
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "i1")),\#(entry("r2", "i1")),\#(entry("r2", "i3"))]}"#]
        ops.rulePages = [Self.rules]
        try await m.refreshApprovals()
        try await m.decideShare("r1", include: ["i1"], decline: [])
        #expect(share(m, "r1") == nil && share(m, "r2")?.items.map(\.itemID) == ["i3"])
    }

    @Test func aBatchForAListedQuestionShowsAtOnce() async throws {
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "A"))]}"#]
        ops.rulePages = [Self.rules]
        let m = manager()
        try await m.refreshApprovals()
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"B","name":"B","category":"other","sensitivity":"data"}]}"#))
        #expect(share(m, "r1")?.items.map(\.itemID) == ["A", "B"])
    }

    @Test func aBatchThatArrivesDuringTheReadIsKeptWithTheListedItems() async throws {
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "A")),\#(entry("r1", "C"))]}"#]
        ops.rulePages = [Self.rules]
        let gate = TestDeferred<Void>()
        ops.pendingGate = gate
        let m = manager()
        let read = Task { try await m.refreshApprovals() }
        #expect(await eventually { ops.shareCalls.contains("pending:nil:500") && ops.pendingPages.isEmpty })
        m.onEvent(event("share.pending", #"{"rule_id":"r1","subject":{"connection_id":"c1"},"items":[{"item_id":"B","name":"B","category":"other","sensitivity":"data"}]}"#))
        m.onEvent(event("sync.event", #"{"kind":"share.decided","rule_id":"r1","included":["C"],"declined":[]}"#))
        gate.complete()
        try await read.value
        #expect(Set(share(m, "r1")?.items.map(\.itemID) ?? []) == ["A", "B"], "A listed, B arrived, C decided meanwhile")
    }

    func started(_ read: @escaping @MainActor () async throws -> Void) async -> Task<Void, any Error> {
        let before = ops.shareCalls.count
        let task = Task { try await read() }
        _ = await eventually { ops.shareCalls.count > before && ops.pendingPages.isEmpty }
        return task
    }

    /// A decision made while a read is on its way is not undone by what the read brings: also for the subject's other
    /// rules, which the decision did not name.
    @Test func aDecisionDuringTheReadIsNotUndoneByIt() async throws {
        // (a) another device decided C of r1 while the read had it.
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "A")),\#(entry("r1", "C"))]}"#]
        ops.rulePages = [Self.rules]
        let gate = TestDeferred<Void>()
        ops.pendingGate = gate
        let m = manager()
        let read = await started { try await m.refreshApprovals() }
        m.onEvent(event("sync.event", #"{"kind":"share.decided","rule_id":"r1","included":["C"],"declined":[]}"#))
        gate.complete()
        try await read.value
        #expect(share(m, "r1")?.items.map(\.itemID) == ["A"])

        // (b) this phone decided i1 of r1 during a read that lists it under r2 too.
        ops.pendingGate = nil
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "i1")),\#(entry("r2", "i1")),\#(entry("r2", "i3"))]}"#]
        ops.rulePages = [Self.rules]
        try await m.refreshApprovals()
        ops.shareAnswer = #"{"included":["i1"],"declined":[]}"#
        let second = TestDeferred<Void>()
        ops.pendingGate = second
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "i1")),\#(entry("r2", "i1")),\#(entry("r2", "i3"))]}"#]
        ops.rulePages = [Self.rules]
        let again = await started { try await m.refreshApprovals() }
        try await m.decideShare("r1", include: ["i1"], decline: [])
        second.complete()
        try await again.value
        #expect(share(m, "r1") == nil && share(m, "r2")?.items.map(\.itemID) == ["i3"])
    }

    /// The marks are the subject's: c1's decision never strips c2's question; and the vault's answer, not the request,
    /// says what a decision changed.
    @Test func aDecisionIsScopedToItsSubjectAndTheAnswersItems() async throws {
        let other = #"{"rule_id":"r3","subject":{"connection_id":"c2"},"item_id":"i1","name":"i1","category":"other","sensitivity":"data"}"#
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "i1")),\#(entry("r2", "i3")),\#(other)]}"#]
        ops.rulePages = [Self.rules]
        let gate = TestDeferred<Void>()
        ops.pendingGate = gate
        let m = manager()
        let read = await started { try await m.refreshApprovals() }
        m.onEvent(event("sync.event", #"{"kind":"share.decided","rule_id":"r1","included":["i1"],"declined":[]}"#))
        gate.complete()
        try await read.value
        #expect(share(m, "r3")?.items.map(\.itemID) == ["i1"] && share(m, "r2")?.items.map(\.itemID) == ["i3"] && share(m, "r1") == nil)

        // The answer lists i3, which the subject's other rule r2 held: it leaves r2 though it was not sent.
        ops.pendingGate = nil
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "i1")),\#(entry("r2", "i3"))]}"#]
        ops.rulePages = [Self.rules]
        try await m.refreshApprovals()
        ops.shareAnswer = #"{"included":["i1","i3"],"declined":[]}"#
        try await m.decideShare("r1", include: ["i1"], decline: [])
        #expect(share(m, "r2") == nil)
    }

    /// Two reads overlap: a decision made after the older began stays marked until the older is done.
    @Test func overlappingReadsKeepTheMarksTheOlderNeeds() async throws {
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "A")),\#(entry("r1", "C"))]}"#]
        ops.rulePages = [Self.rules]
        let gate = TestDeferred<Void>()
        ops.pendingGate = gate
        let m = manager()
        let older = await started { try await m.refreshApprovals() }
        m.onEvent(event("sync.event", #"{"kind":"share.decided","rule_id":"r1","included":["C"],"declined":[]}"#))
        // A newer read, which sees the decision, ends first.
        let free = TestDeferred<Void>()
        ops.pendingGate = free
        ops.pendingPages = [#"{"pending":[\#(entry("r1", "A"))]}"#]
        ops.rulePages = [Self.rules]
        let newer = await started { try await m.refreshApprovals() }
        free.complete()
        try await newer.value
        gate.complete()
        try await older.value
        #expect(share(m, "r1")?.items.map(\.itemID) == ["A"])
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
