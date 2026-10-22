import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// Share rules and grants (VAULT-MESSAGING §10.12): request bodies, parsing, the drafts' checks, how rules are named and
/// overlap, and the fetch. Mirrors the rule and grant tests of vettid-android's `SharingManagerTest`.
@MainActor
@Suite struct SharingRulesTests {
    let ops = FakeSharingOps()
    let m: SharingManager

    init() {
        let ops = ops
        m = SharingManager(ops: { ops })
    }

    func o(_ s: String) throws -> JsonObject { try StrictJson.parseObject(s) }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    /// 2027-01-01T00:00:00Z.
    let newYear = Date(timeIntervalSince1970: 1_798_761_600)
    var soon: Date { Date().addingTimeInterval(30 * 86_400) }

    func rule(_ id: String, _ tags: [String], conn: String = "c1", match: TagMatch = .any, mode: ShareMode = .ask, included: [String] = [], pending: [String] = []) -> ShareRule {
        ShareRule(ruleID: id, version: 1, connectionID: conn, tags: tags, match: match, mode: mode, included: included, pending: pending)
    }

    // MARK: - Rule bodies

    @Test func aRuleBodyNamesTheConnectionAndReadAccess() {
        let b = SharingManager.ruleBody(RuleDraft(connectionID: "c1", tags: ["medical"], match: .all, mode: .auto, uses: 5, expiresAt: newYear, includeExisting: false), dryRun: true)
        #expect(b.raw == #"{"subject":{"connection_id":"c1"},"tags":["medical"],"match":"all","access":"read","mode":"auto","uses":5,"expires_at":"2027-01-01T00:00:00.000Z","include_existing":false,"dry_run":true}"#)
        let replace = SharingManager.ruleBody(RuleDraft(connectionID: "c1", tags: ["a"], ruleID: "r1", version: 4), dryRun: false)
        #expect(VaultJSON.string(replace, "rule_id") == "r1" && VaultJSON.int(replace, "version") == 4 && VaultJSON.string(replace, "mode") == "ask" && !replace.has("dry_run"))
        // A new rule names no version, whatever the draft carries.
        #expect(!SharingManager.ruleBody(RuleDraft(connectionID: "c1", tags: ["a"], version: 4), dryRun: false).has("version"))
    }

    /// Owner feedback 2026-10-09 (rules per tag): `share.rule.set` for a connection carries exactly the §10.12 fields a
    /// connection rule takes, and never `status_ttl`, which is for agent rules only.
    @Test func aSavedConnectionRuleSendsExactlyTheSpecFields() async throws {
        ops.ruleAnswer = #"{"rule_id":"r7","version":1,"subject":{"connection_id":"c1"},"tags":["address"],"mode":"auto"}"#
        let end = soon
        let saved = try await m.saveRule(RuleDraft(connectionID: "c1", tags: ["address", "home"], mode: .auto, uses: 25, expiresAt: end, includeExisting: false))
        #expect(saved.ruleID == "r7" && saved.mode == .auto)
        #expect(ops.ruleSets.map(\.raw) == [#"{"subject":{"connection_id":"c1"},"tags":["address","home"],"match":"any","access":"read","mode":"auto","uses":25,"expires_at":"\#(Timestamps.formatMillis(end))","include_existing":false}"#])
        ops.ruleSets = []
        try await m.saveRule(RuleDraft(connectionID: "c1", tags: ["drivers-license"], ruleID: "r2", version: 3))
        #expect(ops.ruleSets.map(\.raw) == [#"{"rule_id":"r2","version":3,"subject":{"connection_id":"c1"},"tags":["drivers-license"],"match":"any","access":"read","mode":"ask","include_existing":true}"#])
        for k in ["per_hour", "per_day", "status_ttl"] { #expect(!ops.ruleSets[0].has(k)) }
        // The dry run is the same body with dry_run (§10.12).
        ops.ruleSets = []
        ops.ruleAnswer = #"{"matches":[],"total":0}"#
        _ = try await m.preview(RuleDraft(connectionID: "c1", tags: ["drivers-license"], ruleID: "r2", version: 3))
        #expect(ops.ruleSets.map(\.raw) == [#"{"rule_id":"r2","version":3,"subject":{"connection_id":"c1"},"tags":["drivers-license"],"match":"any","access":"read","mode":"ask","include_existing":true,"dry_run":true}"#])
    }

    /// §10.12: one tag, and `per_hour`/`per_day` on a connection rule only when set (absent: no limit).
    @Test func aConnectionRuleSendsItsOneTagAndItsRateLimits() throws {
        let d = RuleDraft(connectionID: "c1", tags: ["medical"], mode: .auto, uses: 3, perHour: 5, perDay: 20)
        #expect(SharingManager.ruleBody(d, dryRun: false).raw == #"{"subject":{"connection_id":"c1"},"tags":["medical"],"match":"any","access":"read","mode":"auto","uses":3,"per_hour":5,"per_day":20,"include_existing":true}"#)
        let bare = SharingManager.ruleBody(RuleDraft(connectionID: "c1", tags: ["medical"]), dryRun: true)
        #expect(!bare.has("per_hour") && !bare.has("per_day"))
        // The ranges as for agents: 1-3,600 and 1-86,400.
        let now = Date(timeIntervalSince1970: 1_791_540_000)
        var e = d
        e.perHour = 3_600
        e.perDay = 86_400
        #expect(e.valid(now: now))
        for (hour, day) in [(3_601, 20), (0, 20), (5, 86_401), (5, 0)] {
            e.perHour = hour
            e.perDay = day
            #expect(!e.valid(now: now), "\(hour) per hour, \(day) per day")
        }
        // A rule as listed carries its limits, and the draft of it too.
        let r = try #require(ShareRule.of(try o(#"{"rule_id":"r1","version":2,"subject":{"connection_id":"c1"},"tags":["medical"],"per_hour":5,"per_day":20}"#)))
        #expect(r.perHour == 5 && r.perDay == 20 && RuleDraft.of(r).perHour == 5 && RuleDraft.of(r).perDay == 20 && RuleDraft.of(r).ruleID == "r1" && RuleDraft.of(r).version == 2)
        #expect(ShareRule.of(try o(#"{"rule_id":"r2","tags":["x"]}"#))?.perHour == nil)
    }

    @Test func anEndAndUsesOutsideTheSpecRangesAreNotSent() {
        let now = Date()
        let day: TimeInterval = 86_400
        #expect(RuleDraft(connectionID: "c1", tags: ["a"], uses: 1).valid(now: now))
        #expect(RuleDraft(connectionID: "c1", tags: ["a"], uses: 10_000).valid(now: now))
        #expect(!RuleDraft(connectionID: "c1", tags: ["a"], uses: 10_001).valid(now: now))
        #expect(RuleDraft(connectionID: "c1", tags: ["a"], expiresAt: now.addingTimeInterval(3_649 * day)).valid(now: now))
        #expect(!RuleDraft(connectionID: "c1", tags: ["a"], expiresAt: now.addingTimeInterval(3_651 * day)).valid(now: now))
        #expect(!RuleDraft(connectionID: "c1", tags: (1...17).map { "t\($0)" }).valid(now: now))
        #expect(RuleDraft(connectionID: "c1", tags: (1...16).map { "t\($0)" }).valid(now: now))
        #expect(RuleDraft.maxRulesPerSubject == 64 && RuleDraft.maxRules == 512 && RuleDraft.maxExpiryDays == 3_650)
    }

    @Test func anInvalidRuleIsNotSent() async {
        #expect(await failure { try await m.saveRule(RuleDraft(connectionID: "c1")) }?.code == "bad_request")
        #expect(!RuleDraft(connectionID: "c1", tags: ["@profile"]).valid(now: Date()))
        #expect(!RuleDraft(connectionID: "c1", tags: ["a"], uses: 0).valid(now: Date()))
        #expect(!RuleDraft(connectionID: "c1", tags: ["a"], expiresAt: Date().addingTimeInterval(-1)).valid(now: Date()))
        #expect(ops.ruleSets.isEmpty)
    }

    // MARK: - Overlaps and names

    /// §10.12: no precedence between a connection's rules; overlaps are the same tag or the same item.
    @Test func overlapsAreRulesNamingTheSameTagOrHoldingTheSameItem() {
        let address = rule("r1", ["address"], mode: .auto, included: ["i1"])
        let license = rule("r2", ["drivers-license"], included: ["i2"])
        let travel = rule("r3", ["travel", "drivers-license"], match: .all, pending: ["i2"])
        let home = rule("r4", ["home"], included: ["i1"])
        let o = RuleOverlaps.of([address, license, travel, home])
        #expect(o["r1"]?.map(\.ruleID) == ["r4"], "same item i1")
        #expect(o["r2"]?.map(\.ruleID) == ["r3"], "same tag and item")
        #expect(o["r3"]?.map(\.ruleID) == ["r2"] && o["r4"]?.map(\.ruleID) == ["r1"])
        // A draft: its own rule never counts; matched items count.
        #expect(RuleOverlaps.forDraft(ruleID: "r2", tags: ["drivers-license"], itemIDs: [], rules: [address, license, travel]).map(\.ruleID) == ["r3"])
        #expect(RuleOverlaps.forDraft(ruleID: nil, tags: ["x"], itemIDs: ["i1"], rules: [address, license]).map(\.ruleID) == ["r1"])
        #expect(RuleOverlaps.sharedTags(["drivers-license", "x"], travel) == ["drivers-license"])
        #expect(RuleOverlaps.sharedItems(["i1", "i2"], travel) == ["i2"])
    }

    /// §10.12 Overlapping rules (0.23.0): an `auto` rule asks first for what an overlapping `ask` rule covers.
    @Test func anAutoRuleAsksFirstWhereAnAskRuleOverlaps() {
        let ask = rule("r1", ["medical"], included: ["i1"])
        let auto = rule("r2", ["insurance"], mode: .auto, included: ["i1"])
        let other = rule("r3", ["money"], mode: .auto)
        let o = RuleOverlaps.of([ask, auto, other])
        #expect(o["r1"]?.map(\.ruleID) == ["r2"])
        #expect(RuleOverlaps.asksFirst(.auto, o["r2"] ?? []).map(\.ruleID) == ["r1"])
        #expect(RuleOverlaps.asksFirst(.ask, o["r1"] ?? []).isEmpty && o["r3"]?.isEmpty == true)
        #expect(rule("r9", ["a", "b"]).multiTag && !ask.multiTag)
    }

    /// §10.12 (owner's review of #181): a rule is named by its tags; two that read the same differ by mode, then end.
    @Test func rulesAreNamedByTheirTags() {
        #expect(RuleNames.text(["medical"], .any) == "medical")
        #expect(RuleNames.text(["medical", "id"], .all) == "medical + id")
        #expect(RuleNames.text(["medical", "id"], .any) == "medical or id")
        let a = rule("r1", ["medical"])
        let b = rule("r2", ["medical"], mode: .auto)
        let c = rule("r3", ["money"])
        let names = RuleNames.of([a, b, c])
        #expect(names["r1"] == RuleNames.Name(text: "medical", qualifier: .mode(.ask)))
        #expect(names["r2"] == RuleNames.Name(text: "medical", qualifier: .mode(.auto)))
        #expect(names["r3"] == RuleNames.Name(text: "money"))
        var d = a
        d.ruleID = "r4"
        d.expiresAt = newYear
        let same = RuleNames.of([a, d])
        #expect(same["r1"]?.qualifier == .ends(nil) && same["r4"]?.qualifier == .ends(newYear))
        #expect(RuleNames.text(a) == "medical")
    }

    // MARK: - The dry run, the save and the delete

    @Test func aPreviewListsTheMatches() async throws {
        ops.ruleAnswer = #"{"matches":[{"item_id":"i1","name":"Allergies","category":"medical","sensitivity":"data"},{"item_id":"i2","name":"Key","category":"crypto_wallet","sensitivity":"critical"},{"name":"no id"}],"total":5}"#
        let p = try await m.preview(RuleDraft(connectionID: "c1", tags: ["medical"]))
        #expect(p.total == 5 && p.matches.map(\.itemID) == ["i1", "i2"] && p.matches[1].sensitivity == .critical)
        #expect(ops.ruleSets.last?.raw.contains(#""dry_run":true"#) == true)
        // Without a total, the matches' count.
        ops.ruleAnswer = #"{"matches":[{"item_id":"i1"}]}"#
        let q = try await m.preview(RuleDraft(connectionID: "c1", tags: ["medical"]))
        #expect(q.total == 1 && q.matches[0].name == "" && q.matches[0].category == "other")
    }

    /// §10.12 dry run (0.23.0): `outcome` and `ask_rule_id` per match; an older vault's matches have neither.
    @Test func theDryRunSaysWhatSavingDoesToEachItem() async throws {
        ops.ruleAnswer = #"{"matches":[{"item_id":"i1","name":"Allergies","category":"medical","sensitivity":"data","outcome":"ask","ask_rule_id":"r1"},{"item_id":"i2","name":"Bank","category":"bank_account","sensitivity":"data","outcome":"include"},{"item_id":"i3","name":"Old","category":"note","sensitivity":"data","state":"included"}],"total":3}"#
        let p = try await m.preview(RuleDraft(connectionID: "c1", tags: ["money"], mode: .auto))
        #expect(p.matches.map(\.outcome) == ["ask", "include", nil] && p.matches.map(\.askRuleID) == ["r1", nil, nil])
        #expect(p.matches[2].state == "included" && p.matches[1].outcome == RuleMatch.outcomeInclude && p.matches[0].outcome == RuleMatch.outcomeAsk)
    }

    @Test func aSaveAndADeleteReadTheRegistryAgain() async throws {
        ops.ruleAnswer = #"{"rule_id":"r7","tags":["a"]}"#
        try await m.saveRule(RuleDraft(connectionID: "c1", tags: ["a"]))
        #expect(ops.calls == ["tagList:nil"], "a rule names tags: the registry's rules changed")
        try await m.deleteRule("r7")
        #expect(ops.calls == ["tagList:nil", "ruleDelete:r7", "tagList:nil"])
        ops.ruleAnswer = #"{"version":1}"#
        #expect(await failure { try await m.saveRule(RuleDraft(connectionID: "c1", tags: ["a"])) }?.code == "unreadable_rule")
    }

    // MARK: - Grants

    @Test func grantsAreSplitGivenAndReceived() async throws {
        let g = try await m.grants()
        #expect(g.given.map(\.name) == ["Allergies"] && g.given[0].usesLeft == 2 && g.given[0].ruleID == "r1" && g.given[0].direction == .given && g.given[0].active)
        #expect(g.received.count == 1 && g.received[0].direction == .received && g.received[0].usesLeft == nil && g.received[0].expiresAt != nil)
        // 0.21.0: a received grant's labels as its descriptor had them (a malformed one skipped); a given one has none.
        #expect(g.received[0].labels == [GrantFieldLabel(fieldID: "f1", label: "Number", kind: "text"), GrantFieldLabel(fieldID: "f3", label: "Valid to", kind: "date")])
        #expect(g.given[0].labels.isEmpty)
        // `requested`: the entries exactly as sent, and the state (pending when absent).
        #expect(g.requested.map(\.requestID) == ["q1", "q2"])
        #expect(g.requested[0].entries == [GrantAskEntry(kind: "category", ref: "medical", label: "Your vaccination record"), GrantAskEntry(kind: "item", ref: "01ITEM")])
        #expect(g.requested[0].state == "granted" && g.requested[1].state == "pending")
    }

    /// §10.12: a grant's `limits` (the rule's, as of issue for a received one); a `rate_limited` fetch's `retry_after`.
    @Test func grantsCarryTheirRateLimitsAndARefusalItsRetry() async throws {
        let g = try #require(GrantView.of(try o(#"{"grant_id":"g1","connection_id":"c1","direction":"received","ref":"x","name":"Card","category":"insurance","limits":{"per_hour":5,"per_day":20}}"#), .received))
        #expect(g.perHour == 5 && g.perDay == 20)
        let none = try #require(GrantView.of(try o(#"{"grant_id":"g2","connection_id":"c1","ref":"x","name":"Card"}"#), .received))
        #expect(none.perHour == nil && none.perDay == nil && none.category == "other" && none.state == GrantView.stateActive && none.fields == nil)
        // A received `limits: {}` means no limits.
        let empty = try #require(GrantView.of(try o(#"{"grant_id":"g3","connection_id":"c1","ref":"x","limits":{}}"#), .received))
        #expect(empty.perHour == nil && empty.perDay == nil)
        ops.fetched = GrantFetched(grantID: "g1", content: nil, usesLeft: nil, error: "rate_limited", retryAfter: 720)
        #expect(try await m.fetchShared("g1") == .refused("rate_limited", retryAfter: 720))
        // A `retry_after` that is not a wait is none; an older vault's unknown error has no retry.
        ops.fetched = GrantFetched(grantID: "g1", content: nil, usesLeft: nil, error: "rate_limited", retryAfter: 0)
        #expect(try await m.fetchShared("g1") == .refused("rate_limited", retryAfter: nil))
        ops.fetched = GrantFetched(grantID: "g1", content: nil, usesLeft: nil, error: "exhausted")
        #expect(try await m.fetchShared("g1") == .refused("exhausted"))
    }

    @Test func aGrantNamesItsFieldsAndLabelsWhereTheVaultDoes() throws {
        let g = try #require(GrantView.of(try o(#"{"grant_id":"g1","connection_id":"c1","direction":"given","ref":"i1","fields":["f1","f2"],"label":"Passport","state":"revoked","uses":2,"used":5}"#), .received))
        #expect(g.direction == .given, "the grant's own direction wins")
        #expect(g.fields == ["f1", "f2"] && g.name == "Passport" && g.label == "Passport" && g.state == "revoked" && !g.active && g.usesLeft == 0)
        let noID = try o(#"{"connection_id":"c1"}"#), noConnection = try o(#"{"grant_id":"g"}"#)
        #expect(GrantView.of(noID, .given) == nil && GrantView.of(noConnection, .given) == nil)
        let ask = try o(#"{"request_id":"q","connection_id":"c","items":[{"kind":"item","ref":"i","label":"  "}]}"#)
        #expect(GrantAsk.of(ask)?.entries == [GrantAskEntry(kind: "item", ref: "i")])
    }

    @Test func aFetchedValueIsParsedAndHandedOver() async throws {
        let pt = #"{"item_id":"x9","version":2,"name":"Insurance card","category":"insurance","fields":[{"field_id":"f1","label":"Policy","kind":"text","value":"P-42"},{"field_id":"f2","label":"Address","kind":"address","value":{"city":"Paris"}},{"field_id":"f3","label":"Empty","kind":"text","value":null}],"notes":"n"}"#
        let fetched = GrantFetched(grantID: "g2", content: Array(pt.utf8), usesLeft: 4, error: nil)
        ops.fetched = fetched
        guard case .shared(let c) = try await m.fetchShared("g2") else { Issue.record("shared"); return }
        #expect(c.name == "Insurance card" && c.itemID == "x9" && c.category == "insurance" && c.notes == "n" && c.usesLeft == 4)
        #expect(c.fields[0].value == .text("P-42") && c.fields[0].fieldID == "f1" && c.fields[0].label == "Policy")
        #expect(c.fields[1].value == .address(AddressValue(city: "Paris")) && c.fields[2].value == nil)
        // The opened content is not kept by what carried it, and the content never prints.
        #expect(fetched.takeContent() == nil)
        #expect(!"\(c)".contains("P-42") && !"\(String(reflecting: c))".contains("Paris") && !"\(fetched)".contains("Insurance"))
        ops.fetched = GrantFetched(grantID: "g2", content: nil, usesLeft: nil, error: "exhausted")
        #expect(try await m.fetchShared("g2") == .refused("exhausted"))
        // Neither content nor error: the connection's vault could not answer.
        ops.fetched = GrantFetched(grantID: "g2", content: nil, usesLeft: nil, error: nil)
        #expect(try await m.fetchShared("g2") == .refused("unavailable"))
        ops.fetched = GrantFetched(grantID: "g2", content: Array("not json".utf8), usesLeft: nil, error: nil)
        #expect(await failure { try await m.fetchShared("g2") }?.code == "unreadable_value")
    }

    @Test func aRequestAsksForACategory() async throws {
        #expect(try await m.requestGrant(connectionID: "c1", category: "insurance", label: " Your insurance card ", reason: "") == "01REQ")
        #expect(ops.asked?.connectionID == "c1" && ops.asked?.item.raw == #"{"kind":"category","ref":"insurance","label":"Your insurance card"}"# && ops.asked?.reason == nil)
        _ = try await m.requestGrant(connectionID: "c1", category: "insurance", label: nil, reason: " for the claim ")
        #expect(ops.asked?.item.raw == #"{"kind":"category","ref":"insurance"}"# && ops.asked?.reason == "for the claim")
        let tooLongLabel = String(repeating: "é", count: 65), tooLongReason = String(repeating: "x", count: 257)
        #expect(await failure { try await m.requestGrant(connectionID: "c1", category: "Not A Category", label: nil, reason: nil) }?.code == "bad_request")
        #expect(await failure { try await m.requestGrant(connectionID: "c1", category: "insurance", label: tooLongLabel, reason: nil) }?.code == "bad_request")
        #expect(await failure { try await m.requestGrant(connectionID: "c1", category: "insurance", label: nil, reason: tooLongReason) }?.code == "bad_request")
        // At the limits: 128 bytes of label, 256 of reason.
        _ = try await m.requestGrant(connectionID: "c1", category: "insurance", label: String(repeating: "é", count: 64), reason: String(repeating: "x", count: 256))
        #expect(SharingManager.maxLabel == 128 && SharingManager.maxReason == 256)
    }

    @Test func aRevokeIsSentForTheGrant() async throws {
        try await m.revokeGrant("g1")
        #expect(ops.calls == ["revoke:g1"])
    }
}

// swiftlint:enable line_length
