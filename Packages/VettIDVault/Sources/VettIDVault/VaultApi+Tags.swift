import Foundation
import VettIDCrypto

/// One tag of `tag.list` (VAULT-MESSAGING §10.8): a registry entry, a tag on an item or one a share rule names, with its
/// presentation ([color] `#rrggbb`, [icon], [description]), how many [items] carry it and the [rules] naming it.
public struct TagEntry: Equatable, Sendable {
    public let tag: String
    public let color: String?
    public let icon: String?
    public let description: String?
    public let items: Int
    public let rules: [String]

    public init(tag: String, color: String? = nil, icon: String? = nil, description: String? = nil, items: Int = 0, rules: [String] = []) {
        self.tag = tag
        self.color = color
        self.icon = icon
        self.description = description
        self.items = items
        self.rules = rules
    }

    /// A `tag.list` entry; nil without its `tag`.
    static func of(_ o: JsonObject) -> TagEntry? {
        guard let tag = VaultJSON.string(o, "tag") else { return nil }
        let items = VaultJSON.int(o, "items").map { Int(clamping: max($0, 0)) } ?? 0
        return TagEntry(
            tag: tag, color: VaultJSON.string(o, "color"), icon: VaultJSON.string(o, "icon"),
            description: VaultJSON.string(o, "description"), items: items, rules: VaultJSON.strings(o, "rules")
        )
    }
}

/// One page of `tag.list` (§10.8): the registry's [version], its tags, and [next] (the last tag returned) when more remain.
public struct TagPage: Equatable, Sendable {
    public let version: Int64
    public let tags: [TagEntry]
    public let next: String?

    public init(version: Int64 = 0, tags: [TagEntry] = [], next: String? = nil) {
        self.version = version
        self.tags = tags
        self.next = next
    }

    static func of(_ o: JsonObject) -> TagPage {
        TagPage(
            version: VaultJSON.int(o, "version") ?? 0, tags: VaultJSON.objects(o, "tags").compactMap(TagEntry.of),
            next: VaultJSON.string(o, "next").flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

// The tag registry (VAULT-MESSAGING §10.8) and the read of the share rules (§10.12) that the tags' screens show. Mirrors
// vettid-android `VaultApi.tagList`, `tagSet`, `tagDelete`, `tagMerge` and `shareRuleList`.
extension VaultApi {
    public static let typeTagList = "tag.list"
    public static let typeTagSet = "tag.set"
    public static let typeTagDelete = "tag.delete"
    public static let typeTagMerge = "tag.merge"
    public static let typeShareRuleList = "share.rule.list"

    private func tagOp(_ type: String, _ b: JsonBuilder) async throws -> JsonObject {
        try StrictJson.parseObject(try await device.op(type, body: b.bytes()))
    }

    /// One page of `tag.list`.
    public func tagList(after: String? = nil, limit: Int? = nil) async throws -> TagPage {
        let b = JsonBuilder()
        if let after { b.string("after", after) }
        if let limit { b.uint("limit", UInt64(max(limit, 0))) }
        return TagPage.of(try await tagOp(Self.typeTagList, b))
    }

    /// `tag.set` against [version]: creates or replaces [tag]'s registry entry (members left nil are cleared); returns
    /// the registry's new version (0 when the vault did not say).
    public func tagSet(
        version: Int64, tag: String, color: String? = nil, icon: String? = nil, description: String? = nil
    ) async throws -> Int64 {
        let b = JsonBuilder().uint("version", UInt64(max(version, 0))).string("tag", tag)
        if let color { b.string("color", color) }
        if let icon { b.string("icon", icon) }
        if let description { b.string("description", description) }
        return VaultJSON.int(try await tagOp(Self.typeTagSet, b), "version") ?? 0
    }

    /// `tag.delete` against [version] (`in_use` while a share rule names it); with [dryRun] it changes nothing and says
    /// what it would do: `{version, items}`.
    public func tagDelete(version: Int64, tag: String, dryRun: Bool = false) async throws -> JsonObject {
        let b = JsonBuilder().uint("version", UInt64(max(version, 0))).string("tag", tag)
        if dryRun { b.bool("dry_run", true) }
        return try await tagOp(Self.typeTagDelete, b)
    }

    /// `tag.merge` of [from] into [into] against [version] (a rename is a merge of one tag): `{version, items, rules,
    /// shares, shares_total}`, with [dryRun] what it would do.
    public func tagMerge(version: Int64, from: [String], into: String, dryRun: Bool = false) async throws -> JsonObject {
        let b = JsonBuilder().uint("version", UInt64(max(version, 0))).raw("from", JsonBuilder.array(from.map(JsonBuilder.quote)))
            .string("into", into)
        if dryRun { b.bool("dry_run", true) }
        return try await tagOp(Self.typeTagMerge, b)
    }

    /// One page of `share.rule.list` (§10.12), of [connectionID] or [agentID] when given: `{rules, next?}`.
    public func shareRuleList(connectionID: String? = nil, agentID: String? = nil, after: String? = nil) async throws -> JsonObject {
        let b = JsonBuilder()
        if let connectionID { b.string("connection_id", connectionID) }
        if let agentID { b.string("agent_id", agentID) }
        if let after { b.string("after", after) }
        return try await tagOp(Self.typeShareRuleList, b)
    }
}
