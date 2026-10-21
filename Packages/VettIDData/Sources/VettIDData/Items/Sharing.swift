import Foundation
import VettIDCrypto
import VettIDVault

/// A tag of the registry or in use (VAULT-MESSAGING §10.8 `tag.list`): how many items carry it and which share rules name
/// it, and its stored presentation ([color] `#rrggbb`, [icon], [description]), which `tag.set` replaces as a whole.
/// Mirrors vettid-android `TagView`.
public struct TagView: Equatable, Hashable, Sendable, Identifiable {
    public var tag: String
    public var items: Int
    public var rules: [String]
    public var color: String?
    public var description: String?
    public var icon: String?

    public init(tag: String, items: Int = 0, rules: [String] = [], color: String? = nil, description: String? = nil, icon: String? = nil) {
        self.tag = tag
        self.items = items
        self.rules = rules
        self.color = color
        self.description = description
        self.icon = icon
    }

    public var id: String { tag }
    public var reserved: Bool { tag.hasPrefix("@") }
}

/// The tag registry as last listed; [version] is what `tag.set`, `.delete` and `.merge` name (§10.1). Mirrors
/// vettid-android `TagRegistry`.
public struct TagRegistry: Equatable, Sendable {
    public var version: Int64
    public var tags: [TagView]

    public init(version: Int64, tags: [TagView]) {
        self.version = version
        self.tags = tags
    }
}

/// An item a tag change would share, and how (§10.8 `tag.merge`'s `shares`). Mirrors vettid-android `SharePreview`.
public struct SharePreview: Equatable, Sendable {
    public var ruleID: String
    public var itemID: String
    public var mode: ShareMode

    public init(ruleID: String, itemID: String, mode: ShareMode) {
        self.ruleID = ruleID
        self.itemID = itemID
        self.mode = mode
    }
}

/// What a tag delete or merge does, or would do with `dry_run` (§10.8): [items] changed, [rules] changed, and the items
/// it shares ([shares], at most what fits; [sharesTotal] counts them all). Mirrors vettid-android `TagChange`.
public struct TagChange: Equatable, Sendable {
    public var version: Int64
    public var items: Int
    public var rules: Int
    public var shares: [SharePreview]
    public var sharesTotal: Int

    public init(version: Int64, items: Int, rules: Int = 0, shares: [SharePreview] = [], sharesTotal: Int = 0) {
        self.version = version
        self.items = items
        self.rules = rules
        self.shares = shares
        self.sharesTotal = sharesTotal
    }

    /// A `tag.delete` or `tag.merge` answer.
    public static func of(_ o: JsonObject) -> TagChange {
        let n = { (k: String) in VaultJSON.int(o, k).map { Int(clamping: $0) } ?? 0 }
        let shares = VaultJSON.objects(o, "shares").compactMap { s -> SharePreview? in
            guard let r = VaultJSON.string(s, "rule_id"), let i = VaultJSON.string(s, "item_id") else { return nil }
            return SharePreview(ruleID: r, itemID: i, mode: ShareMode.of(VaultJSON.string(s, "mode")))
        }
        return TagChange(
            version: VaultJSON.int(o, "version") ?? 0, items: n("items"), rules: n("rules"), shares: shares, sharesTotal: n("shares_total")
        )
    }
}

/// Whether a rule needs one of its tags on an item (`any`, the default) or all of them (§10.12). Mirrors vettid-android
/// `TagMatch`.
public enum TagMatch: String, Sendable {
    case any
    case all

    public var wire: String { rawValue }

    public static func of(_ w: String?) -> TagMatch { w == TagMatch.all.rawValue ? .all : .any }
}

/// A share rule (§10.12): a connection (or agent) may read the items whose tags match. Read here for the tags' screens
/// (which rules name a tag, what an item's tags share); the rules are edited with the sharing screens (IOS-PLAN §8 I3.2).
/// Mirrors vettid-android `ShareRule`.
public struct ShareRule: Equatable, Sendable, Identifiable {
    public var ruleID: String
    public var version: Int64
    public var connectionID: String?
    public var agentID: String?
    public var tags: [String]
    public var match: TagMatch
    public var mode: ShareMode
    public var uses: Int?
    public var expiresAt: Date?
    public var includeExisting: Bool
    /// How often the subject may fetch the rule's items in total, per hour and per day (§10.12; 0.23.0 for connections).
    public var perHour: Int?
    public var perDay: Int?
    public var included: [String]
    public var pending: [String]
    public var declined: [String]
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        ruleID: String, version: Int64 = 1, connectionID: String?, agentID: String? = nil, tags: [String], match: TagMatch = .any,
        mode: ShareMode = .ask, uses: Int? = nil, expiresAt: Date? = nil, includeExisting: Bool = true, perHour: Int? = nil,
        perDay: Int? = nil, included: [String] = [], pending: [String] = [], declined: [String] = [], createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.ruleID = ruleID
        self.version = version
        self.connectionID = connectionID
        self.agentID = agentID
        self.tags = tags
        self.match = match
        self.mode = mode
        self.uses = uses
        self.expiresAt = expiresAt
        self.includeExisting = includeExisting
        self.perHour = perHour
        self.perDay = perDay
        self.included = included
        self.pending = pending
        self.declined = declined
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var id: String { ruleID }

    /// Whether an item with [itemTags] matches the rule's tags (§10.12; whether it is in force is the vault's).
    public func matches(_ itemTags: [String]) -> Bool {
        switch match {
        case .any: tags.contains(where: itemTags.contains)
        case .all: tags.allSatisfy(itemTags.contains)
        }
    }

    /// One tag per rule (owner decision 2026-10-09): a rule naming several is shown, and can only be deleted.
    public var multiTag: Bool { tags.count > 1 }

    /// A `<share_rule>`; nil without its id.
    public static func of(_ o: JsonObject) -> ShareRule? {
        guard let id = VaultJSON.string(o, "rule_id") else { return nil }
        let subject = VaultJSON.obj(o, "subject")
        let n = { (k: String) in VaultJSON.int(o, k).map { Int(clamping: $0) } }
        return ShareRule(
            ruleID: id, version: VaultJSON.int(o, "version") ?? 0,
            connectionID: subject.flatMap { VaultJSON.string($0, "connection_id") },
            agentID: subject.flatMap { VaultJSON.string($0, "agent_id") }, tags: VaultJSON.strings(o, "tags"),
            match: TagMatch.of(VaultJSON.string(o, "match")), mode: ShareMode.of(VaultJSON.string(o, "mode")), uses: n("uses"),
            expiresAt: OwnerCheckManager.instant(VaultJSON.string(o, "expires_at")),
            includeExisting: VaultJSON.bool(o, "include_existing") ?? true, perHour: n("per_hour"), perDay: n("per_day"),
            included: VaultJSON.strings(o, "included"), pending: VaultJSON.strings(o, "pending"),
            declined: VaultJSON.strings(o, "declined"),
            createdAt: OwnerCheckManager.instant(VaultJSON.string(o, "created_at")),
            updatedAt: OwnerCheckManager.instant(VaultJSON.string(o, "updated_at"))
        )
    }
}
