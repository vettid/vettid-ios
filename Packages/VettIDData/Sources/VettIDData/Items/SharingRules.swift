import Foundation
import VettIDCrypto
import VettIDVault

/// A share rule as the member edits it; [ruleID] nil for a new one (VAULT-MESSAGING §10.12). Mirrors vettid-android
/// `RuleDraft`.
public struct RuleDraft: Equatable, Sendable {
    public var connectionID: String
    public var tags: [String]
    public var match: TagMatch
    public var mode: ShareMode
    public var uses: Int?
    public var expiresAt: Date?
    public var includeExisting: Bool
    public var ruleID: String?
    public var version: Int64?
    /// §10.12 (0.23.0): optional for a connection rule, absent means no limit.
    public var perHour: Int?
    public var perDay: Int?

    public init(
        connectionID: String, tags: [String] = [], match: TagMatch = .any, mode: ShareMode = .ask, uses: Int? = nil,
        expiresAt: Date? = nil, includeExisting: Bool = true, ruleID: String? = nil, version: Int64? = nil, perHour: Int? = nil,
        perDay: Int? = nil
    ) {
        self.connectionID = connectionID
        self.tags = tags
        self.match = match
        self.mode = mode
        self.uses = uses
        self.expiresAt = expiresAt
        self.includeExisting = includeExisting
        self.ruleID = ruleID
        self.version = version
        self.perHour = perHour
        self.perDay = perDay
    }

    /// A rule names 1–16 tags, none reserved (§10.12).
    public static let maxTags = 16
    public static let maxUses = 10_000
    /// §10.12 (0.23.0): `per_hour` 1–3,600 and `per_day` 1–86,400, as for agents.
    public static let maxPerHour = 3_600
    public static let maxPerDay = 86_400
    /// At most 3,650 days ahead (§10.12).
    public static let maxExpiryDays = 3_650
    /// A vault holds at most 64 share rules per subject (limit `share_rules_subject`) and 512 in all (`share_rules`), §10.12.
    public static let maxRulesPerSubject = 64
    public static let maxRules = 512
    private static let daySeconds: TimeInterval = 86_400

    /// The draft of an existing rule, to edit it.
    public static func of(_ r: ShareRule) -> RuleDraft {
        RuleDraft(
            connectionID: r.connectionID ?? "", tags: r.tags, match: r.match, mode: r.mode, uses: r.uses, expiresAt: r.expiresAt,
            includeExisting: r.includeExisting, ruleID: r.ruleID, version: r.version, perHour: r.perHour, perDay: r.perDay
        )
    }

    /// The rule's checks before it is sent (§10.12).
    public func valid(now: Date) -> Bool {
        guard (1...Self.maxTags).contains(tags.count), !tags.contains(where: { $0.hasPrefix("@") }) else { return false }
        guard uses.map({ (1...Self.maxUses).contains($0) }) ?? true else { return false }
        guard perHour.map({ (1...Self.maxPerHour).contains($0) }) ?? true else { return false }
        guard perDay.map({ (1...Self.maxPerDay).contains($0) }) ?? true else { return false }
        guard let end = expiresAt else { return true }
        return end > now && end < now.addingTimeInterval(TimeInterval(Self.maxExpiryDays) * Self.daySeconds)
    }
}

/// Where share rules for one subject cover the same tags or items (§10.12 Overlapping rules, 0.23.0): `ask` wins. An item
/// that any covering rule of the subject asks about is shared with that subject only after the member approves it, even
/// when another covering rule is `auto`; one answer per item and subject; removing an `ask` rule never shares anything;
/// and the strictest limits apply (a fetch counts in every including rule's windows and uses). Mirrors vettid-android
/// `RuleOverlaps`.
public enum RuleOverlaps {
    /// Each rule's id → the other rules that name one of its tags or hold one of its items (included or pending).
    public static func of(_ rules: [ShareRule]) -> [String: [ShareRule]] {
        var out: [String: [ShareRule]] = [:]
        for r in rules {
            out[r.ruleID] = rules.filter { o in o.ruleID != r.ruleID && overlap(r.tags, r.included + r.pending, o) }
        }
        return out
    }

    /// The saved rules (other than the draft's own) that cover the draft's [tags] or one of [itemIDs] (the dry run's
    /// matches), in the order given.
    public static func forDraft(ruleID: String?, tags: [String], itemIDs: [String], rules: [ShareRule]) -> [ShareRule] {
        rules.filter { o in o.ruleID != ruleID && overlap(tags, itemIDs, o) }
    }

    /// The tags [a] shares with [b].
    public static func sharedTags(_ a: [String], _ b: ShareRule) -> [String] { a.filter { b.tags.contains($0) } }

    /// The items of [itemIDs] that [rule] already includes or asks about.
    public static func sharedItems(_ itemIDs: [String], _ rule: ShareRule) -> Set<String> {
        Set(itemIDs.filter { rule.included.contains($0) || rule.pending.contains($0) })
    }

    /// The `ask` rules among [others] that an `auto` rule asks first for (none for an `ask` rule).
    public static func asksFirst(_ mode: ShareMode, _ others: [ShareRule]) -> [ShareRule] {
        mode == .auto ? others.filter { $0.mode == .ask } : []
    }

    private static func overlap(_ tags: [String], _ items: [String], _ o: ShareRule) -> Bool {
        tags.contains(where: o.tags.contains) || items.contains { o.included.contains($0) || o.pending.contains($0) }
    }
}

/// How a rule is named to the member (§10.12, owner's review of #181): rules have no names, so a rule is its tags in the
/// rule's order, joined by " + " for `match: all` and " or " for `any`. Two rules of one subject that would read the same
/// are told apart by their mode, then their end (``Qualifier``). Mirrors vettid-android `RuleNames`.
public enum RuleNames {
    /// The words between a rule's tags.
    public static let allJoin = " + "
    public static let anyJoin = " or "

    /// What tells two rules that read the same apart.
    public enum Qualifier: Equatable, Sendable {
        case mode(ShareMode)
        case ends(Date?)
    }

    public struct Name: Equatable, Sendable {
        public var text: String
        public var qualifier: Qualifier?

        public init(text: String, qualifier: Qualifier? = nil) {
            self.text = text
            self.qualifier = qualifier
        }
    }

    /// [tags] as one name: "medical", "medical + id" (all), "medical or id" (any).
    public static func text(_ tags: [String], _ match: TagMatch) -> String {
        tags.joined(separator: match == .all ? allJoin : anyJoin)
    }

    public static func text(_ r: ShareRule) -> String { text(r.tags, r.match) }

    /// Every rule's name among [rules] (one subject), with what differs where two would read the same.
    public static func of(_ rules: [ShareRule]) -> [String: Name] {
        var out: [String: Name] = [:]
        for (text, same) in Dictionary(grouping: rules, by: { text($0) }) {
            if same.count == 1 {
                out[same[0].ruleID] = Name(text: text)
                continue
            }
            let byMode = Set(same.map(\.mode)).count == same.count
            for r in same { out[r.ruleID] = Name(text: text, qualifier: byMode ? .mode(r.mode) : .ends(r.expiresAt)) }
        }
        return out
    }
}

/// An item a rule matches, from `share.rule.set{dry_run}` (§10.12); [state] for a replaced rule. Mirrors vettid-android
/// `RuleMatch`.
public struct RuleMatch: Equatable, Sendable, Identifiable {
    public static let outcomeInclude = "include"
    public static let outcomeAsk = "ask"

    public var itemID: String
    public var name: String
    public var category: String
    public var sensitivity: Sensitivity
    public var state: String?
    /// 0.23.0: what saving would do to the item in this rule, ``outcomeInclude`` (shared at once) or ``outcomeAsk`` (the
    /// member is asked); nil when its state would not change, or from an older vault.
    public var outcome: String?
    /// 0.23.0: an `auto` rule would ask because this `ask` rule of the same subject holds the item.
    public var askRuleID: String?

    public init(
        itemID: String, name: String, category: String, sensitivity: Sensitivity, state: String? = nil, outcome: String? = nil,
        askRuleID: String? = nil
    ) {
        self.itemID = itemID
        self.name = name
        self.category = category
        self.sensitivity = sensitivity
        self.state = state
        self.outcome = outcome
        self.askRuleID = askRuleID
    }

    public var id: String { itemID }
}

/// What a draft rule would match (`share.rule.set{dry_run}`): the [matches] listed and their [total]. Mirrors vettid-android
/// `RulePreview`.
public struct RulePreview: Equatable, Sendable {
    public var matches: [RuleMatch]
    public var total: Int

    public init(matches: [RuleMatch], total: Int) {
        self.matches = matches
        self.total = total
    }
}
