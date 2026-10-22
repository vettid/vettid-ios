import Foundation
import VettIDCrypto
import VettIDVault

/// The member's pending share decisions (VAULT-MESSAGING §10.12), over the vault's pages so that it can be tested without a
/// vault. Since 0.21.0 the vault lists them (`share.pending.list`): the app builds its decisions from that list, so that one
/// another device left open, or whose `share.pending` it missed, is still asked. For a vault that does not know the type
/// (before 0.21.0; the fallback is kept as vettid-android keeps it) the app reads every rule's `pending` ids. Mirrors
/// vettid-android `SharePending` (its `decisions`; the decision itself is ``ApprovalsManager/decideShare(_:include:decline:)``).
enum SharePending {
    /// `share.pending.list`'s largest page (§10.12: 1–500), and at most the vault's 4,096 pending items.
    static let page = 500
    static let maxPending = 4_096

    /// A vault that does not know the type answers `unsupported_type` or `bad_request`.
    private static func unknownType(_ e: VaultOpError) -> Bool { e.code == "unsupported_type" || e.code == "bad_request" }

    /// The decisions waiting, one per rule: from [pendingPage] (`share.pending.list` from `after`, 0.21.0), with each rule's
    /// tags from [rulePage] (`share.rule.list`; none if it fails). A vault that does not know the type: every rule's
    /// `pending` ids, named from [names] (the item list).
    @MainActor
    static func decisions(
        pendingPage: (String?) async throws -> JsonObject, rulePage: (String?) async throws -> JsonObject,
        names: [String: ShareItem], at t: Date
    ) async throws -> [ShareDecision] {
        let pending: [JsonObject]
        do {
            pending = try await pages(pendingPage, "pending", maxPending)
        } catch let e as VaultOpError where unknownType(e) {
            return fromRules(try await pages(rulePage, "rules", .max), names, t)
        }
        let rules = (try? await pages(rulePage, "rules", .max))?.compactMap(ShareRule.of) ?? []
        var order: [String] = []
        var byRule: [String: [JsonObject]] = [:]
        for e in pending {
            guard let rule = VaultJSON.string(e, "rule_id"), !rule.isEmpty else { continue }
            if byRule[rule] == nil { order.append(rule) }
            byRule[rule, default: []].append(e)
        }
        return order.map { rule in
            let entries = byRule[rule] ?? []
            let subject = entries.first.flatMap { VaultJSON.obj($0, "subject") }
            var seen = Set<String>()
            let items = entries.compactMap(ApprovalParser.shareItem).filter { seen.insert($0.itemID).inserted }
            return ShareDecision(
                ruleID: rule, subjectConnectionID: subject.flatMap { VaultJSON.string($0, "connection_id") },
                subjectAgentID: subject.flatMap { VaultJSON.string($0, "agent_id") }, items: items, reason: nil,
                receivedAt: entries.compactMap { ApprovalParser.instant(VaultJSON.string($0, "at")) }.max() ?? t,
                tags: rules.first { $0.ruleID == rule }?.tags ?? [], rules: sameSubject(rules, subject)
            )
        }
    }

    /// The rules of [subject] (a connection or an agent), to name the one that asks (§10.12, 0.23.0).
    private static func sameSubject(_ rules: [ShareRule], _ subject: JsonObject?) -> [ShareRule] {
        let c = subject.flatMap { VaultJSON.string($0, "connection_id") }
        let a = subject.flatMap { VaultJSON.string($0, "agent_id") }
        if c == nil, a == nil { return [] }
        return rules.filter { (c != nil && $0.connectionID == c) || (a != nil && $0.agentID == a) }
    }

    /// Every page's [key] entries (`next` passed back as `after`), at most [max].
    @MainActor
    private static func pages(_ page: (String?) async throws -> JsonObject, _ key: String, _ max: Int) async throws -> [JsonObject] {
        var out: [JsonObject] = []
        var after: String?
        repeat {
            let p = try await page(after)
            let entries = VaultJSON.objects(p, key)
            out += entries
            after = entries.isEmpty ? nil : VaultJSON.nonEmpty(p, "next")
        } while after != nil && out.count < max
        return out
    }

    /// Before 0.21.0: every rule's `pending` ids, named from the item list where it has them.
    private static func fromRules(_ rules: [JsonObject], _ names: [String: ShareItem], _ t: Date) -> [ShareDecision] {
        let parsed = rules.compactMap(ShareRule.of)
        return rules.compactMap { r in
            guard let id = VaultJSON.string(r, "rule_id") else { return nil }
            let pending = VaultJSON.strings(r, "pending")
            if pending.isEmpty { return nil }
            let subject = VaultJSON.obj(r, "subject")
            return ShareDecision(
                ruleID: id, subjectConnectionID: subject.flatMap { VaultJSON.string($0, "connection_id") },
                subjectAgentID: subject.flatMap { VaultJSON.string($0, "agent_id") },
                items: pending.map { names[$0] ?? ShareItem(itemID: $0, name: "", category: "other", sensitivity: "data") },
                reason: nil, receivedAt: ApprovalParser.instant(VaultJSON.string(r, "updated_at")) ?? t,
                tags: VaultJSON.strings(r, "tags"), rules: sameSubject(parsed, subject)
            )
        }
    }
}
