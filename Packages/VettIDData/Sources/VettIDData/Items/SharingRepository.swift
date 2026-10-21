import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// Tags and sharing (VAULT-MESSAGING §10.8 tags, §10.12 share rules), as ``Repositories.swift`` describes the
/// repositories. Every failure is a ``VaultFailure``; a tag a share rule names cannot be deleted
/// (``FailureKind/inUse``). This row has the tag registry and the read of the rules; the rules' edits and the grants come
/// with the sharing screens (IOS-PLAN §8 I3.2). Mirrors vettid-android `SharingRepository`.
@MainActor
public protocol SharingRepository: AnyObject, Observable, Sendable {
    /// The tag registry and the tags in use, as last listed; nil before, and again after another device changed the tags
    /// (`tag.changed`) or a tag was first used on an item, until read again.
    var tags: TagRegistry? { get }

    /// The colours the registry stores (§10.8 `color`), by tag, as last listed: kept while the registry is read again
    /// after a `tag.changed`, empty once the vault is not open. Tags without one show their hash colour.
    var colors: [String: String] { get }

    /// Reads the registry (`tag.list`, every page).
    @discardableResult
    func refreshTags() async throws -> TagRegistry

    /// The same as a read nobody asked for (the colour keeper's): only over the session open now, and not while the vault
    /// is held or due (nil then).
    @discardableResult
    func refreshTagsQuietly() async throws -> TagRegistry?

    /// Creates or replaces a registry entry (`tag.set`); [description] at most 256 bytes. `tag.set` clears what it is not
    /// sent, so the entry's stored icon goes with it unchanged.
    func setTag(_ tag: String, description: String?, color: String?) async throws

    /// The member's choice of colour for [tag] (`tag.set`, owner decision 2026-10-09), its description and icon kept;
    /// after a `conflict` (another device changed the registry) the registry is read again and the choice sent once more.
    /// Never for an `@` tag (`@profile` is always the member's gold).
    func setTagColor(_ tag: String, color: String) async throws

    /// Stores a colour for every tag that has none (owner decision 2026-10-09): [next] picks the next tag and its
    /// `#rrggbb` from the registry, nil when none is left; each is sent with `tag.set` (the registry's version, the tag's
    /// description and icon kept), one at a time. A `conflict` re-reads the registry and goes on with what is stored there
    /// (a colour another device stored is kept); any other failure stops, the rest waiting for the next time. Returns how
    /// many were stored.
    func assignColors(_ next: @escaping ([TagView]) -> (tag: String, color: String)?) async throws -> Int

    /// Tags just put on an item: one the registry has no colour for makes it read again (and so coloured).
    func onTagsUsed(_ tags: [String])

    /// Renames [from] to [into] (a merge of one tag, §10.8); [dryRun] only says what it would do.
    func renameTag(_ from: String, into: String, dryRun: Bool) async throws -> TagChange

    /// Removes the tag from the registry and every item (`tag.delete`); `in_use` while a share rule names it.
    func deleteTag(_ tag: String, dryRun: Bool) async throws -> TagChange

    /// Every share rule (of [connectionID] when given), sorted by `rule_id`.
    func rules(connectionID: String?) async throws -> [ShareRule]
}

/// The vault calls behind ``SharingManager``, so that it can be tested without a vault. Mirrors vettid-android
/// `SharingOps` (the calls of this row).
public protocol SharingOps: Sendable {
    func tagList(after: String?) async throws -> TagPage
    func tagSet(version: Int64, tag: String, color: String?, icon: String?, description: String?) async throws -> Int64
    func tagMerge(version: Int64, from: [String], into: String, dryRun: Bool) async throws -> JsonObject
    func tagDelete(version: Int64, tag: String, dryRun: Bool) async throws -> JsonObject
    func ruleList(connectionID: String?, after: String?) async throws -> JsonObject
}

/// ``SharingOps`` over the vault client. Mirrors vettid-android `VaultSharingOps`.
struct VaultSharingOps: SharingOps {
    let api: VaultApi

    func tagList(after: String?) async throws -> TagPage { try await api.tagList(after: after) }

    func tagSet(version: Int64, tag: String, color: String?, icon: String?, description: String?) async throws -> Int64 {
        try await api.tagSet(version: version, tag: tag, color: color, icon: icon, description: description)
    }

    func tagMerge(version: Int64, from: [String], into: String, dryRun: Bool) async throws -> JsonObject {
        try await api.tagMerge(version: version, from: from, into: into, dryRun: dryRun)
    }

    func tagDelete(version: Int64, tag: String, dryRun: Bool) async throws -> JsonObject {
        try await api.tagDelete(version: version, tag: tag, dryRun: dryRun)
    }

    func ruleList(connectionID: String?, after: String?) async throws -> JsonObject {
        try await api.shareRuleList(connectionID: connectionID, after: after)
    }
}
