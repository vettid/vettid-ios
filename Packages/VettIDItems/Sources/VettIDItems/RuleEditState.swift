import Foundation
import VettIDData

/// The share-rule editor's state. Mirrors vettid-android `RuleEditUiState`.
public struct RuleEditState: Equatable, Sendable, Failing {
    public var draft: RuleDraft
    public var connectionName: String?
    /// The member's tags a rule can name (no reserved tag, §10.12).
    public var tags: [String] = []
    public var expiry: RuleExpiry = .never
    public var usesText = ""
    /// §10.12 (0.23.0): fetches of all the rule's items together per hour (1–3,600) and per day (1–86,400); empty: none.
    public var perHourText = ""
    public var perDayText = ""
    public var preview: RulePreview?
    public var previewing = false
    public var loading = false
    public var busy = false
    public var error: FailureKind?
    /// The code an unmapped refusal names (shown with ``error``), or nil.
    public var errorCode: String?
    /// The limit a `limit` error named (VAULT-MESSAGING 0.21.0 §10.1).
    public var limit: VaultLimit?
    public var confirmDelete = false
    public var done = false
    /// Every rule of this connection as last listed (the edited one included).
    public var rules: [ShareRule] = []
    /// The custom end's pickers, while open.
    public var endPicker: EndPicker?
    /// The custom end picked was not in the future or more than 3,650 days ahead.
    public var endInvalid = false
    /// Something was changed since the rule was opened: leaving asks "Discard changes to this rule?".
    public var dirty = false
    public var confirmDiscard = false
    /// A rule naming several tags (made before one tag per rule, owner decision 2026-10-09): shown as it is and can be
    /// deleted, not changed, so that nothing it shares changes by surprise. A rule per tag replaces it.
    public var readOnly = false

    public init(draft: RuleDraft, connectionName: String? = nil, loading: Bool = false) {
        self.draft = draft
        self.connectionName = connectionName
        self.loading = loading
    }

    public var isNew: Bool { draft.ruleID == nil }

    public var usesValid: Bool { Self.valid(usesText, RuleDraft.maxUses) }
    public var perHourValid: Bool { Self.valid(perHourText, RuleDraft.maxPerHour) }
    public var perDayValid: Bool { Self.valid(perDayText, RuleDraft.maxPerDay) }

    private static func valid(_ text: String, _ max: Int) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || Int(text).map { (1...max).contains($0) } == true
    }

    /// A new rule while the connection has the most it can have (§10.12 `share_rules_subject`, 64).
    public var atRuleLimit: Bool { isNew && rules.count >= RuleDraft.maxRulesPerSubject }

    /// The one tag chosen (one tag per rule, owner decision 2026-10-09).
    public var tag: String? { draft.tags.count == 1 ? draft.tags[0] : nil }

    /// Tags another rule of this connection already shares on its own, → that rule: "Already shared — edit its rule".
    public var taken: [String: String] {
        var out: [String: String] = [:]
        for r in rules where r.ruleID != draft.ruleID && r.tags.count == 1 { out[r.tags[0]] = r.ruleID }
        return out
    }

    /// The tags this rule can take.
    public var freeTags: [String] {
        let t = taken
        return tags.filter { t[$0] == nil }
    }

    /// Save is offered once a tag is chosen and every limit reads.
    public var canSave: Bool { !readOnly && tag != nil && usesValid && perHourValid && perDayValid && !busy && !atRuleLimit && !loading }

    /// The connection's other rules covering the same tags or matched items (§10.12 Overlapping rules: `ask` wins).
    public var overlaps: [ShareRule] {
        RuleOverlaps.forDraft(ruleID: draft.ruleID, tags: draft.tags, itemIDs: preview?.matches.map(\.itemID) ?? [], rules: rules)
    }

    /// How each rule of the connection is named (§10.12: by its tags).
    public var names: [String: RuleNames.Name] { RuleNames.of(rules) }
}
