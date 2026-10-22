import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
@testable import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// VAULT-MESSAGING 0.21.0 §10.12: pending share decisions from `share.pending.list`, with the 0.23.0 members, and what the
/// approvals make of them. Mirrors vettid-android's `SharePendingTest` (`decisions`; the decision itself is
/// `ApprovalsManagerTests`) and `ShareQuestionsTest`.
@MainActor
@Suite struct SharePendingTests {
    let t = Date(timeIntervalSince1970: 1_791_460_800)

    func o(_ s: String) throws -> JsonObject { try StrictJson.parseObject(s) }

    var rules: JsonObject {
        get throws {
            try o(#"{"rules":[{"rule_id":"01R1","subject":{"connection_id":"c1"},"tags":["medical"],"pending":["01I9"]},{"rule_id":"01R2","subject":{"connection_id":"c2"},"tags":["travel","id"],"pending":[]}]}"#)
        }
    }

    func error(_ code: String) -> VaultOpError { VaultOpError(type: "share.pending.list", code: code, detail: "", body: nil) }

    @Test func theVaultsListIsReadPageByPageAndGroupedByRule() async throws {
        var asked: [String?] = []
        var pages = [
            try o(#"{"pending":[{"rule_id":"01R1","subject":{"connection_id":"c1"},"item_id":"01I1","name":"Allergies","category":"medical","sensitivity":"data","at":"2026-10-08T10:00:00.000Z"}],"next":"opaque-1"}"#),
            try o(#"{"pending":[{"rule_id":"01R1","subject":{"connection_id":"c1"},"item_id":"01I2","name":"Signing key","category":"crypto_wallet","sensitivity":"critical","at":"2026-10-08T11:00:00.000Z"},{"rule_id":"01R2","subject":{"connection_id":"c2"},"item_id":"01I3","name":"Passport","category":"identity_document","sensitivity":"data","at":"2026-10-07T09:00:00.000Z"}]}"#),
        ]
        let rules = try rules
        let d = try await SharePending.decisions(
            pendingPage: { after in
                asked.append(after)
                return pages.removeFirst()
            }, rulePage: { _ in rules }, names: [:], at: t
        )
        #expect(asked == [nil, "opaque-1"])
        #expect(d.map(\.ruleID) == ["01R1", "01R2"])
        let r1 = d[0]
        #expect(r1.subjectConnectionID == "c1")
        #expect(r1.items == [ShareItem(itemID: "01I1", name: "Allergies", category: "medical", sensitivity: "data"), ShareItem(itemID: "01I2", name: "Signing key", category: "crypto_wallet", sensitivity: "critical")])
        // The newest item's time; the rule's tags from share.rule.list (its own `pending` ids are not used).
        #expect(r1.receivedAt == OwnerCheckManager.instant("2026-10-08T11:00:00Z") && r1.tags == ["medical"] && d[1].tags == ["travel", "id"])
    }

    @Test func theRulesTagsAreOptional() async throws {
        let page = try o(#"{"pending":[{"rule_id":"01R1","item_id":"01I1","name":"A","category":"medical","sensitivity":"data"}]}"#)
        let d = try await SharePending.decisions(pendingPage: { _ in page }, rulePage: { _ in throw self.error("unavailable") }, names: [:], at: t)
        #expect(d.single?.tags.isEmpty == true && d.single?.receivedAt == t)
    }

    @Test func anOlderVaultsRulesAreReadInstead() async throws {
        let rules = try rules
        for refusal in ["unsupported_type", "bad_request"] {
            let d = try await SharePending.decisions(
                pendingPage: { _ in throw self.error(refusal) }, rulePage: { _ in rules },
                names: ["01I9": ShareItem(itemID: "01I9", name: "Blood type", category: "medical", sensitivity: "data")], at: t
            )
            #expect(d.single?.ruleID == "01R1" && d.single?.items.single?.name == "Blood type" && d.single?.tags == ["medical"])
        }
        // An item the app has no name for is unnamed, `other`.
        let unnamed = try await SharePending.decisions(pendingPage: { _ in throw self.error("unsupported_type") }, rulePage: { _ in rules }, names: [:], at: t)
        #expect(unnamed.single?.items == [ShareItem(itemID: "01I9", name: "", category: "other", sensitivity: "data")])
    }

    @Test func anotherFailureIsNotHidden() async throws {
        let rules = try rules
        do {
            _ = try await SharePending.decisions(pendingPage: { _ in throw self.error("limit") }, rulePage: { _ in rules }, names: [:], at: t)
            Issue.record("a limit is the member's to see")
        } catch let e as VaultOpError {
            #expect(e.code == "limit")
        }
    }

    /// 0.23.0: entries carry `ask_rule_id` and `shared`; each decision gets its subject's rules, to name the one that asks.
    @Test func entriesSayWhichRuleAsksAndWhatIsAlreadyShared() async throws {
        let two = try o(#"{"rules":[{"rule_id":"01R1","subject":{"connection_id":"c1"},"tags":["medical"]},{"rule_id":"01R2","subject":{"connection_id":"c1"},"tags":["insurance"],"mode":"auto"},{"rule_id":"01R3","subject":{"connection_id":"c2"},"tags":["x"]}]}"#)
        let page = try o(#"{"pending":[{"rule_id":"01R2","subject":{"connection_id":"c1"},"item_id":"01I1","name":"Allergies","category":"medical","sensitivity":"data","ask_rule_id":"01R1","shared":false},{"rule_id":"01R2","subject":{"connection_id":"c1"},"item_id":"01I2","name":"Card","category":"insurance","sensitivity":"data","shared":true}]}"#)
        let d = try await SharePending.decisions(pendingPage: { _ in page }, rulePage: { _ in two }, names: [:], at: t)
        let r2 = try #require(d.single)
        #expect(r2.items.map(\.askRuleID) == ["01R1", nil] && r2.items.map(\.shared) == [false, true])
        #expect(r2.rules.map(\.ruleID) == ["01R1", "01R2"], "c1's rules only")
        #expect(r2.rule?.ruleID == "01R2" && r2.rule?.mode == .auto)
    }

    // MARK: - One question per item and subject

    func decision(_ rule: String, _ conn: String?, _ items: [ShareItem], agent: String? = nil) -> PendingApproval {
        .share(ShareDecision(ruleID: rule, subjectConnectionID: conn, subjectAgentID: agent, items: items, reason: nil, receivedAt: t))
    }

    func item(_ id: String, ask: String? = nil) -> ShareItem { ShareItem(itemID: id, name: id, category: "other", sensitivity: "data", askRuleID: ask) }

    var auth: PendingApproval { .authentication(AuthenticationRequest(requestID: "a1", connectionID: "c1", context: nil, receivedAt: t, exp: nil)) }

    func shares(_ list: [PendingApproval]) -> [String: ShareDecision] {
        var out: [String: ShareDecision] = [:]
        for case .share(let s) in list { out[s.ruleID] = s }
        return out
    }

    @Test func anItemWaitingInSeveralRulesOfOneConnectionIsAskedOnce() {
        let out = shares(ShareQuestions.dedupe([
            decision("r2", "c1", [item("i1", ask: "r1"), item("i2")]),
            decision("r1", "c1", [item("i1"), item("i3")]),
            // Another connection's rule is another subject: asked there too.
            decision("r5", "c2", [item("i1")]),
            auth,
        ]))
        // r1 comes first by rule_id: it asks about i1 (noting r2), and r2 keeps only i2.
        #expect(out["r1"]?.items.map(\.itemID) == ["i1", "i3"] && out["r1"]?.items[0].alsoIn == ["r2"])
        #expect(out["r2"]?.items.map(\.itemID) == ["i2"])
        #expect(out["r5"]?.items.map(\.itemID) == ["i1"] && out["r5"]?.items[0].alsoIn == [])
    }

    @Test func aRuleLeftWithNothingOfItsOwnIsNotShownAndOtherApprovalsStay() {
        let out = ShareQuestions.dedupe([decision("r1", "c1", [item("i1")]), decision("r2", "c1", [item("i1", ask: "r1")]), auth])
        #expect(out.map(\.key) == ["share:r1", "auth:a1"])
        guard case .share(let kept) = out[0] else { Issue.record("a share decision"); return }
        #expect(kept.items.single?.alsoIn == ["r2"])
        // Agents are subjects too; a single decision is left as it is.
        let one = [decision("r9", nil, [item("i1")], agent: "ag1")]
        #expect(ShareQuestions.dedupe(one) == one)
        let twoAgents = ShareQuestions.dedupe([decision("r8", nil, [item("i1")], agent: "ag1"), decision("r9", nil, [item("i1")], agent: "ag1")])
        #expect(twoAgents.map(\.key) == ["share:r8"])
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

// swiftlint:enable line_length
