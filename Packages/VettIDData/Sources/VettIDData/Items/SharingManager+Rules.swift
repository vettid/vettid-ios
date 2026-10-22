import Foundation
import VettIDCrypto
import VettIDVault

// The share rules' edits (VAULT-MESSAGING §10.12): the dry run, the save and the delete, and the bodies and answers they
// speak. Mirrors vettid-android `SharingManager` (`preview`, `saveRule`, `deleteRule`, `ruleBody`).
extension SharingManager {
    public func preview(_ draft: RuleDraft) async throws -> RulePreview {
        let body = Self.ruleBody(draft, dryRun: true)
        return RulePreview.of(try await run { try await ops().ruleSet(body) })
    }

    @discardableResult
    public func saveRule(_ draft: RuleDraft) async throws -> ShareRule {
        guard draft.valid(now: Date()) else { throw Self.badRequest() }
        let mark = cleared
        let body = Self.ruleBody(draft, dryRun: false)
        let o = try await run { try await ops().ruleSet(body) }
        await afterWrite(mark)
        guard let rule = ShareRule.of(o) else { throw VaultFailure(.other, code: "unreadable_rule") }
        return rule
    }

    public func deleteRule(_ ruleID: String) async throws {
        let mark = cleared
        try await run { try await ops().ruleDelete(ruleID) }
        await afterWrite(mark)
    }

    /// `share.rule.set`'s body (§10.12): a connection subject, read access; `per_hour` and `per_day` only when set (0.23.0).
    /// A replacement names its `rule_id` and `version`; with [dryRun] it asks for the matches only.
    public nonisolated static func ruleBody(_ d: RuleDraft, dryRun: Bool) -> JsonObject {
        let b = JsonBuilder()
        if let id = d.ruleID {
            b.string("rule_id", id)
            if let v = d.version { b.uint("version", UInt64(max(v, 0))) }
        }
        b.raw("subject", JsonBuilder().string("connection_id", d.connectionID).build())
        b.raw("tags", JsonBuilder.array(d.tags.map(JsonBuilder.quote)))
        b.string("match", d.match.wire).string("access", "read").string("mode", d.mode.wire)
        if let uses = d.uses { b.uint("uses", UInt64(max(uses, 0))) }
        if let h = d.perHour { b.uint("per_hour", UInt64(max(h, 0))) }
        if let day = d.perDay { b.uint("per_day", UInt64(max(day, 0))) }
        if let end = d.expiresAt { b.string("expires_at", Timestamps.formatMillis(end)) }
        b.bool("include_existing", d.includeExisting)
        if dryRun { b.bool("dry_run", true) }
        return VaultJSON.object(b.bytes())
    }
}

extension RuleMatch {
    /// An entry of a dry run's `matches` (§10.12); nil without its `item_id`.
    public static func of(_ m: JsonObject) -> RuleMatch? {
        guard let id = VaultJSON.string(m, "item_id") else { return nil }
        return RuleMatch(
            itemID: id, name: VaultJSON.string(m, "name") ?? "", category: VaultJSON.string(m, "category") ?? "other",
            sensitivity: Sensitivity.of(VaultJSON.string(m, "sensitivity")), state: VaultJSON.string(m, "state"),
            outcome: VaultJSON.string(m, "outcome"), askRuleID: VaultJSON.string(m, "ask_rule_id")
        )
    }
}

extension RulePreview {
    /// A dry run's answer (`{matches, total}`); `total` is the matches' count when the vault did not say.
    public static func of(_ o: JsonObject) -> RulePreview {
        let matches = VaultJSON.objects(o, "matches").compactMap(RuleMatch.of)
        return RulePreview(matches: matches, total: VaultJSON.int(o, "total").map { Int(clamping: $0) } ?? matches.count)
    }
}
