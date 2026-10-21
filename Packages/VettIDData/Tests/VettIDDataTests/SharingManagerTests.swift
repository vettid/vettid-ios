import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault calls of ``SharingManager``: every call recorded, answers set by the test, every member behind a
/// lock. Mirrors the `Ops` of vettid-android's `SharingManagerTest` (the tags and the read of the rules).
final class FakeSharingOps: SharingOps, @unchecked Sendable {
    @TestLocked var calls: [String] = []
    @TestLocked var tagPages: [TagPage] = []
    @TestLocked var rulePages: [String] = []
    /// Codes `tag.set` answers with, one per call, before it succeeds.
    @TestLocked var setErrors: [String] = []
    @TestLocked var deleteError: String?

    static func error(_ type: String, _ code: String) -> VaultOpError { VaultOpError(type: type, code: code, detail: "", body: nil) }

    func tagList(after: String?) async throws -> TagPage {
        calls.append("tagList:\(after ?? "nil")")
        return tagPages.isEmpty ? TagPage(version: 1) : tagPages.removeFirst()
    }

    func tagSet(version: Int64, tag: String, color: String?, icon: String?, description: String?) async throws -> Int64 {
        calls.append("tagSet:\(version):\(tag):\(color ?? "nil"):\(icon ?? "nil"):\(description ?? "nil")")
        if !setErrors.isEmpty { throw Self.error("tag.set", setErrors.removeFirst()) }
        return version + 1
    }

    func tagMerge(version: Int64, from: [String], into: String, dryRun: Bool) async throws -> JsonObject {
        calls.append("tagMerge:\(version):\(from):\(into):\(dryRun)")
        return try StrictJson.parseObject(#"{"version":\#(version),"items":3,"rules":1,"shares":[{"rule_id":"r1","item_id":"i1","mode":"auto"},{"rule_id":"r2","item_id":"i2","mode":"ask"},{"rule_id":"r3"}],"shares_total":2}"#)
    }

    func tagDelete(version: Int64, tag: String, dryRun: Bool) async throws -> JsonObject {
        calls.append("tagDelete:\(version):\(tag):\(dryRun)")
        if let deleteError { throw Self.error("tag.delete", deleteError) }
        return try StrictJson.parseObject(#"{"version":\#(version),"items":4}"#)
    }

    func ruleList(connectionID: String?, after: String?) async throws -> JsonObject {
        calls.append("ruleList:\(connectionID ?? "nil"):\(after ?? "nil")")
        return try StrictJson.parseObject(rulePages.isEmpty ? "{}" : rulePages.removeFirst())
    }
}

/// Tags and the read of the share rules (VAULT-MESSAGING §10.8, §10.12): request bodies, parsing and the colours. Mirrors
/// the tag tests of vettid-android's `SharingManagerTest`.
@MainActor
@Suite struct SharingManagerTests {
    let ops = FakeSharingOps()
    let itemsRefreshed = Counter()
    let m: SharingManager

    init() {
        let ops = ops, refreshed = itemsRefreshed
        m = SharingManager(ops: { ops }, onItemsChanged: { refreshed.n += 1 })
    }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    func page(_ v: Int64, _ t: TagEntry...) -> TagPage { TagPage(version: v, tags: t) }

    /// The test's colour picker: the first tag without a colour (by name, never `@`), numbered by the colours stored.
    let next: ([TagView]) -> (tag: String, color: String)? = { tags in
        tags.filter { !$0.tag.hasPrefix("@") && $0.color == nil }.min { $0.tag < $1.tag }.map { ($0.tag, "#00000\(tags.count { $0.color != nil })") }
    }

    @Test func theRegistryIsListedPageByPage() async throws {
        ops.tagPages = [TagPage(version: 7, tags: [TagEntry(tag: "@profile", items: 2), TagEntry(tag: "medical", items: 3, rules: ["r1"])], next: "medical"), TagPage(version: 7, tags: [TagEntry(tag: "travel", description: "Trips")])]
        let r = try await m.refreshTags()
        #expect(r.version == 7 && r.tags.map(\.tag) == ["@profile", "medical", "travel"])
        #expect(r.tags[0].reserved && r.tags[1].rules == ["r1"] && r.tags[2].description == "Trips")
        #expect(ops.calls == ["tagList:nil", "tagList:medical"] && m.tags == r)
    }

    @Test func renameIsAMergeOfOneTagAndShowsWhatItShares() async throws {
        ops.tagPages = [TagPage(version: 5)]
        let c = try await m.renameTag("health", into: " Medical ", dryRun: true)
        #expect(ops.calls.contains(#"tagMerge:5:["health"]:medical:true"#))
        #expect(c.items == 3 && c.rules == 1 && c.sharesTotal == 2 && c.shares.map(\.mode) == [.auto, .ask] && c.shares.count == 2)
        #expect(itemsRefreshed.n == 0)
        _ = try await m.renameTag("health", into: "medical", dryRun: false)
        #expect(itemsRefreshed.n == 1)
    }

    /// A share an `ask` rule holds back names it (§10.8, 0.23.1 `ask_rule_id`) and is not automatic.
    @Test func aPreviewNamesTheAskRuleThatHoldsAShare() throws {
        let c = TagChange.of(try StrictJson.parseObject(#"{"version":4,"items":1,"shares_total":2,"shares":[{"rule_id":"r1","item_id":"i1","mode":"auto","ask_rule_id":"r9"},{"rule_id":"r2","item_id":"i2","mode":"auto"}]}"#))
        #expect(c.shares.map(\.askRuleID) == ["r9", nil] && c.shares.map(\.automatic) == [false, true] && c.sharesTotal == 2)
    }

    @Test func reservedTagsAreNeitherRenamedNorDeleted() async {
        #expect(await failure { try await m.renameTag("@profile", into: "x", dryRun: false) }?.code == "bad_request")
        #expect(await failure { try await m.deleteTag("@profile", dryRun: false) }?.code == "bad_request")
        #expect(await failure { try await m.renameTag("a", into: "@profile", dryRun: false) }?.code == "bad_request")
        #expect(await failure { try await m.setTag("!", description: nil, color: nil) }?.code == "bad_request")
        #expect(!ops.calls.contains { $0.hasPrefix("tagMerge") || $0.hasPrefix("tagDelete") || $0.hasPrefix("tagSet") })
    }

    @Test func aTagARuleNamesIsInUse() async {
        ops.deleteError = "in_use"
        #expect(await failure { try await m.deleteTag("medical", dryRun: true) }?.kind == .inUse)
    }

    @Test func rulesAreListedPageByPage() async throws {
        ops.rulePages = [
            #"{"rules":[{"rule_id":"r1","version":2,"subject":{"connection_id":"c1"},"tags":["medical"],"match":"all","mode":"auto","uses":5,"per_hour":10,"included":["i1"],"pending":["i2"],"declined":["i3"],"include_existing":false},{"no":"id"}],"next":"r1"}"#,
            #"{"rules":[{"rule_id":"r2","subject":{"agent_id":"a1"},"tags":["travel","work"]}]}"#,
        ]
        let rules = try await m.rules(connectionID: nil)
        #expect(ops.calls == ["ruleList:nil:nil", "ruleList:nil:r1"])
        #expect(rules.map(\.ruleID) == ["r1", "r2"])
        let r = rules[0]
        #expect(r.connectionID == "c1" && r.match == .all && r.mode == .auto && r.uses == 5 && r.perHour == 10 && r.perDay == nil && !r.includeExisting)
        #expect(r.included == ["i1"] && r.pending == ["i2"] && r.declined == ["i3"] && r.version == 2)
        #expect(r.matches(["medical", "x"]) && !r.matches(["x"]))
        #expect(rules[1].agentID == "a1" && rules[1].multiTag && rules[1].mode == .ask && rules[1].includeExisting)
    }

    @Test func coloursAreStoredOneAtATimeWithTheDescriptionAndIconKept() async throws {
        ops.tagPages = [page(4, TagEntry(tag: "@profile", items: 1), TagEntry(tag: "travel", icon: "plane", description: "Trips"), TagEntry(tag: "medical", color: "#ff0000"), TagEntry(tag: "home"))]
        #expect(try await m.assignColors(next) == 2)
        // Sorted order, each with the version the last one answered; the profile never.
        #expect(ops.calls == ["tagList:nil", "tagSet:4:home:#000001:nil:nil", "tagSet:5:travel:#000002:plane:Trips"])
        #expect(m.colors == ["medical": "#ff0000", "home": "#000001", "travel": "#000002"] && m.tags?.version == 6)
        // Nothing left: no more writes.
        ops.calls = []
        #expect(try await m.assignColors(next) == 0)
        #expect(!ops.calls.contains { $0.hasPrefix("tagSet") })
    }

    @Test func aConflictReadsTheRegistryAgainAndKeepsWhatAnotherDeviceStored() async throws {
        // Another device stored "a" meanwhile.
        ops.tagPages = [page(4, TagEntry(tag: "a"), TagEntry(tag: "b")), page(6, TagEntry(tag: "a", color: "#abcdef"), TagEntry(tag: "b"))]
        ops.setErrors = ["conflict"]
        #expect(try await m.assignColors(next) == 1)
        #expect(ops.calls == ["tagList:nil", "tagSet:4:a:#000000:nil:nil", "tagList:nil", "tagSet:6:b:#000001:nil:nil"])
        #expect(m.colors == ["a": "#abcdef", "b": "#000001"])
    }

    @Test func anyOtherFailureStopsQuietly() async throws {
        ops.tagPages = [page(4, TagEntry(tag: "a"), TagEntry(tag: "b"))]
        ops.setErrors = ["owner_check_required"]
        #expect(try await m.assignColors(next) == 0)
        #expect(ops.calls.count { $0.hasPrefix("tagSet") } == 1 && m.colors.isEmpty)
    }

    /// Conflicts forever, each re-read still uncoloured: one write, then one per conflict up to 8, the 9th conflict ends it.
    @Test func conflictsAreBoundedAtEight() async throws {
        ops.tagPages = Array(repeating: page(4, TagEntry(tag: "a"), TagEntry(tag: "b")), count: 12)
        ops.setErrors = Array(repeating: "conflict", count: 100)
        #expect(try await m.assignColors(next) == 0)
        #expect(ops.calls.count { $0.hasPrefix("tagSet") } == SharingManager.maxConflicts + 1)
        #expect(ops.calls.count { $0.hasPrefix("tagList") } == SharingManager.maxConflicts + 1, "the first read and one per conflict")
    }

    @Test func atMost512ColoursInOneGo() async throws {
        ops.tagPages = [TagPage(version: 1, tags: (0..<600).map { TagEntry(tag: String(format: "t%03d", $0)) })]
        let palette: ([TagView]) -> (tag: String, color: String)? = { tags in tags.first { $0.color == nil }.map { ($0.tag, "#000000") } }
        #expect(try await m.assignColors(palette) == SharingManager.maxAssigned)
        #expect(ops.calls.count { $0.hasPrefix("tagSet") } == 512)
    }

    /// The keeper's work stops at a clear or when the vault becomes held or due, and publishes nothing after it; its reads
    /// and writes go over the quiet calls, never noted as the member's requests.
    @Test func theKeepersWorkIsQuietAndStopsAtAClearOrTheHold() async throws {
        let loud = FakeSharingOps(), noted = Counter(), due = Counter()
        let quiet = ops
        let notes = FailureNotes(mark: { 0 }, note: { e, _, _ in noted.n += 1; return e })
        let m2 = SharingManager(ops: { loud }, quietOps: { quiet }, notes: notes, gated: { due.n == 1 })
        ops.tagPages = [page(4, TagEntry(tag: "a"), TagEntry(tag: "b"), TagEntry(tag: "c"))]
        ops.setErrors = ["credential_required"]
        #expect(try await m2.assignColors(next) == 0)
        #expect(loud.calls.isEmpty && noted.n == 0, "quiet calls only, nothing noted")
        // A clear while a write is on its way: nothing published, no further write.
        ops.calls = []
        let gate = TestDeferred<Void>()
        let slow = GatedSetOps(inner: ops, gate: gate)
        let m3 = SharingManager(ops: { slow }, quietOps: { slow })
        ops.tagPages = [page(4, TagEntry(tag: "a"), TagEntry(tag: "b"))]
        let task = Task { try await m3.assignColors(next) }
        #expect(await eventually { slow.waiting })
        m3.clear()
        gate.complete()
        #expect(try await task.value == 1)
        #expect(m3.tags == nil && m3.colors.isEmpty && ops.calls.count { $0.hasPrefix("tagSet") } == 1)
        // Held or due: nothing at all.
        due.n = 1
        #expect(try await m2.assignColors(next) == 0)
    }

    /// The re-read after the member's write is quiet, and none follows a clear.
    @Test func theReadAfterAWriteIsQuietAndNoneAfterAClear() async throws {
        let loud = ops, quiet = FakeSharingOps()
        let m2 = SharingManager(ops: { loud }, quietOps: { quiet })
        ops.tagPages = [page(4, TagEntry(tag: "travel"))]
        try await m2.setTag("travel", description: "Trips", color: nil)
        #expect(loud.calls == ["tagList:nil", "tagSet:4:travel:nil:nil:Trips"] && quiet.calls == ["tagList:nil"])
        let gate = TestDeferred<Void>()
        let slow = GatedSetOps(inner: loud, gate: gate)
        let m3 = SharingManager(ops: { slow }, quietOps: { quiet })
        ops.tagPages = [page(5, TagEntry(tag: "travel"))]
        let task = Task { try await m3.setTag("travel", description: "x", color: nil) }
        #expect(await eventually { slow.waiting })
        m3.clear()
        gate.complete()
        try await task.value
        #expect(quiet.calls == ["tagList:nil"] && m3.tags == nil, "no read after the clear")
    }

    @Test func theMembersColourKeepsTheEntryAndIsSentAgainAfterAConflict() async throws {
        ops.tagPages = [page(4, TagEntry(tag: "travel", color: "#000001", icon: "plane", description: "Trips")), page(7, TagEntry(tag: "travel", color: "#000003", icon: "plane", description: "Trips, all"))]
        ops.setErrors = ["conflict"]
        try await m.setTagColor("travel", color: "#59bbfb")
        #expect(ops.calls == ["tagList:nil", "tagSet:4:travel:#59bbfb:plane:Trips", "tagList:nil", "tagSet:7:travel:#59bbfb:plane:Trips, all", "tagList:nil"])
        #expect(await failure { try await m.setTagColor("@profile", color: "#59bbfb") }?.kind == .other, "@profile has no colour stored")
    }

    @Test func aDescriptionEditKeepsTheColourAndTheIcon() async throws {
        ops.tagPages = [page(4, TagEntry(tag: "travel", color: "#000001", icon: "plane", description: "Trips"))]
        try await m.refreshTags()
        try await m.setTag("travel", description: "Holidays", color: "#000001")
        #expect(ops.calls.contains("tagSet:4:travel:#000001:plane:Holidays"))
        try await m.setTag("travel", description: "  ", color: nil)
        #expect(ops.calls.last { $0.hasPrefix("tagSet") }?.hasSuffix(":nil") == true, "a blank description is none")
    }

    @Test func coloursOutliveATagChangedUntilReadAgainAndGoOnClear() async throws {
        ops.tagPages = [page(4, TagEntry(tag: "travel", color: "#000001"))]
        try await m.refreshTags()
        m.onEvent(VaultMessage(inner: Inner(id: Ulid.new(), type: "sync.event", ts: Date(), body: Array(#"{"kind":"tag.changed","version":5}"#.utf8))))
        #expect(m.tags == nil && m.colors == ["travel": "#000001"])
        m.clear()
        #expect(m.colors.isEmpty)
    }

    @Test func aTagFirstUsedOnAnItemMakesTheRegistryReadAgain() async throws {
        ops.tagPages = [page(4, TagEntry(tag: "travel", color: "#000001"))]
        try await m.refreshTags()
        m.onTagsUsed(["travel", "@profile"])
        #expect(m.tags?.version == 4)
        m.onTagsUsed(["travel", "garden"])
        #expect(m.tags == nil)
    }

    /// (Chosen; not in the spec) A registry answered after a clear is not kept, and no quiet read goes out while gated.
    @Test func aListAnsweredAfterAClearIsNotKeptAndNothingQuietWhileDue() async throws {
        let due = Counter()
        due.n = 1
        let ops = ops
        let m2 = SharingManager(ops: { ops }, gated: { due.n == 1 })
        #expect(try await m2.refreshTagsQuietly() == nil && ops.calls.isEmpty)
        ops.tagPages = [page(4, TagEntry(tag: "travel"))]
        let gate = TestDeferred<Void>()
        let slow = SlowTagOps(inner: ops, gate: gate)
        let m3 = SharingManager(ops: { slow })
        let task = Task { try await m3.refreshTags() }
        #expect(await eventually { ops.calls.isEmpty && slow.waiting })
        m3.clear()
        gate.complete()
        _ = try await task.value
        #expect(m3.tags == nil && m3.colors.isEmpty)
    }
}

/// ``FakeSharingOps`` whose `tag.set` waits for [gate].
private final class GatedSetOps: SharingOps, @unchecked Sendable {
    let inner: FakeSharingOps
    let gate: TestDeferred<Void>
    @TestLocked var waiting = false

    init(inner: FakeSharingOps, gate: TestDeferred<Void>) {
        self.inner = inner
        self.gate = gate
    }

    func tagList(after: String?) async throws -> TagPage { try await inner.tagList(after: after) }

    func tagSet(version: Int64, tag: String, color: String?, icon: String?, description: String?) async throws -> Int64 {
        waiting = true
        try await gate.value()
        return try await inner.tagSet(version: version, tag: tag, color: color, icon: icon, description: description)
    }

    func tagMerge(version: Int64, from: [String], into: String, dryRun: Bool) async throws -> JsonObject {
        try await inner.tagMerge(version: version, from: from, into: into, dryRun: dryRun)
    }

    func tagDelete(version: Int64, tag: String, dryRun: Bool) async throws -> JsonObject {
        try await inner.tagDelete(version: version, tag: tag, dryRun: dryRun)
    }

    func ruleList(connectionID: String?, after: String?) async throws -> JsonObject {
        try await inner.ruleList(connectionID: connectionID, after: after)
    }
}

/// ``FakeSharingOps`` whose `tag.list` waits for [gate].
private final class SlowTagOps: SharingOps, @unchecked Sendable {
    let inner: FakeSharingOps
    let gate: TestDeferred<Void>
    @TestLocked var waiting = false

    init(inner: FakeSharingOps, gate: TestDeferred<Void>) {
        self.inner = inner
        self.gate = gate
    }

    func tagList(after: String?) async throws -> TagPage {
        waiting = true
        try await gate.value()
        return try await inner.tagList(after: after)
    }

    func tagSet(version: Int64, tag: String, color: String?, icon: String?, description: String?) async throws -> Int64 {
        try await inner.tagSet(version: version, tag: tag, color: color, icon: icon, description: description)
    }

    func tagMerge(version: Int64, from: [String], into: String, dryRun: Bool) async throws -> JsonObject {
        try await inner.tagMerge(version: version, from: from, into: into, dryRun: dryRun)
    }

    func tagDelete(version: Int64, tag: String, dryRun: Bool) async throws -> JsonObject {
        try await inner.tagDelete(version: version, tag: tag, dryRun: dryRun)
    }

    func ruleList(connectionID: String?, after: String?) async throws -> JsonObject {
        try await inner.ruleList(connectionID: connectionID, after: after)
    }
}

// swiftlint:enable line_length
