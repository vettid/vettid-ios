import Foundation
import Observation
import VettIDCrypto
import VettIDVault

/// The member's items (VAULT-MESSAGING §10.7; the "Vault" screens), as ``Repositories.swift`` describes the repositories.
/// Every failure is a ``VaultFailure``: a wrong credential password is ``FailureKind/badPassword``, its backoff
/// ``FailureKind/backoff`` with ``VaultFailure/retryAfterSeconds``. Critical items are credential operations (§3.5.3):
/// their content travels sealed to a UTK, their values come back sealed to a one-time reply key. The list holds metadata
/// only; values are never kept here, and those handed out live with the screen that asked for them, which drops them when
/// ``cleared`` changes (the vault locked, held or due, or this phone wiped). Mirrors vettid-android `ItemsRepository`.
@MainActor
public protocol ItemsRepository: AnyObject, Observable, Sendable {
    /// Every item's metadata (no values), as last listed; refreshed on `item.changed`, `item.deleted` and `tag.changed`.
    var items: [ItemSummary] { get }

    var load: ListLoad { get }

    /// Counts every clear (a lock, the hold, a wipe): screens drop the values and drafts they hold when it changes, and an
    /// answer asked for before it is not handed out (chosen; not in the spec: the iPhone's rule for what was read from a
    /// vault that is no longer open, as for photos).
    var cleared: Int { get }

    /// Reads the whole list (`item.list`, pages of 500).
    func refresh() async throws

    /// `item.get`: a `data` item with its values; a `secret` or `critical` one without.
    func get(_ itemID: String) async throws -> ItemDetail

    /// `item.reveal` of a `secret` (or `data`) item: its values, audited as `item.revealed`.
    func reveal(_ itemID: String) async throws -> ItemDetail

    /// `item.reveal` of a `critical` item with the credential password: the values sealed to a one-time reply key, opened
    /// here and the plaintext wiped.
    func revealCritical(_ itemID: String, password: String) async throws -> ItemDetail

    /// Creates a `data` or `secret` item; returns its id. The draft must pass ``ItemChecks/check(_:)``.
    func create(_ draft: ItemDraft) async throws -> String

    /// Creates a `critical` item inside the credential with the password; returns its id.
    func createCritical(_ draft: ItemDraft, password: String) async throws -> String

    /// Replaces a `data` or `secret` item's content and tags ([version] the one it was based on; `conflict` otherwise).
    /// Kept values (0.21.0) go without `value`: a secret item is edited without `item.reveal`. A vault that gave no `size`
    /// (before 0.21.0) cannot keep values: the app reads them (`item.reveal`, never shown) and sends them all.
    func update(_ itemID: String, version: Int64, draft: ItemDraft) async throws -> Int64

    /// Replaces a `critical` item's content (sealed) and tags with the password: one credential operation, the kept values
    /// merged by the vault. A vault before 0.21.0 refuses fields without `value` (`bad_request`); the app then opens the
    /// values with the same password and sends them all.
    func updateCritical(_ itemID: String, version: Int64, draft: ItemDraft, password: String) async throws -> Int64

    /// `item.delete`; a `critical` item needs the [password]. Withdraws it from every share rule and revokes its grants.
    func delete(_ itemID: String, sensitivity: Sensitivity, password: String?) async throws

    /// `item.tag` (no password, for every sensitivity); returns the new version.
    func setTags(_ itemID: String, version: Int64, tags: [String]) async throws -> Int64

    /// `item.sensitivity`: `data` ↔ `secret` is a metadata change; to or from `critical` is a credential operation
    /// ([password] required). The app warns before an item leaves `critical`.
    func setSensitivity(_ itemID: String, version: Int64, from: Sensitivity, to: Sensitivity, password: String?) async throws -> Int64

    /// What saving the item with [tags] would do to sharing (`item.put{dry_run: true}`, 0.21.0), changing nothing:
    /// [itemID] nil for a new item of [sensitivity]. Never carries the content, so a vault before 0.21.0 refuses it
    /// (`bad_request`) rather than saving; the caller then falls back to the share rules.
    func shareEffect(_ itemID: String?, version: Int64?, sensitivity: Sensitivity, tags: [String]) async throws -> ShareEffect
}

public extension ItemsRepository {
    /// The items' names by id once the list is read (History's item names and "Deleted item"); nil before.
    var names: [String: String]? {
        guard load == .loaded else { return nil }
        return Dictionary(items.map { ($0.itemID, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// The item of [itemID] in the list, if it holds it.
    func summary(_ itemID: String) -> ItemSummary? { items.first { $0.itemID == itemID } }
}

/// The vault calls behind ``ItemsManager`` (§10.7), so that it can be tested without a vault. Errors are the vault
/// client's (``VaultOpError`` with the spec's code), mapped by the manager. Mirrors vettid-android `ItemsOps`.
public protocol ItemOps: Sendable {
    func list(after: String?, limit: Int) async throws -> ItemPage
    func get(_ itemID: String) async throws -> Item
    func reveal(_ itemID: String) async throws -> Item
    /// The opened `values_sealed` plaintext, `{"fields": [{field_id, value}], "notes"?}`; the caller wipes it.
    func revealCritical(password: String, itemID: String) async throws -> SecretBytes
    func put(_ content: ItemContent, sensitivity: String?, tags: [String]?, itemID: String?, version: Int64?) async throws -> ItemRef
    func putCritical(password: String, content: ItemContent, tags: [String]?, itemID: String?, version: Int64?) async throws -> ItemRef
    func tag(_ itemID: String, version: Int64, tags: [String]) async throws -> Int64
    /// `item.put{dry_run: true, item_id?, version?, sensitivity?, tags?}` (§10.7 Dry run, 0.21.0): never the content.
    func putDryRun(itemID: String?, version: Int64?, sensitivity: String?, tags: [String]?) async throws -> JsonObject
    func sensitivity(_ itemID: String, version: Int64, sensitivity: String, password: String?) async throws -> Int64
    func delete(_ itemID: String, password: String?) async throws
}

/// ``ItemOps`` over the vault client. The gate of the credential operations runs in ``ItemsManager``, before the session
/// is opened. Mirrors vettid-android `VaultItemsOps`.
struct VaultItemOps: ItemOps {
    let api: VaultApi

    func list(after: String?, limit: Int) async throws -> ItemPage { try await api.itemList(after: after, limit: limit) }

    func get(_ itemID: String) async throws -> Item { try await api.itemGet(itemID) }

    func reveal(_ itemID: String) async throws -> Item { try await api.itemReveal(itemID) }

    func revealCritical(password: String, itemID: String) async throws -> SecretBytes {
        // No local is kept: the box holds the only reference to the opened bytes, so its wipe zeroes them in place.
        SecretBytes(try await api.itemRevealCritical(password: password, itemID: itemID))
    }

    func put(_ content: ItemContent, sensitivity: String?, tags: [String]?, itemID: String?, version: Int64?) async throws -> ItemRef {
        try await api.itemPut(content, sensitivity: sensitivity, tags: tags, itemID: itemID, version: version)
    }

    func putCritical(password: String, content: ItemContent, tags: [String]?, itemID: String?, version: Int64?) async throws -> ItemRef {
        try await api.itemPutCritical(password: password, content: content, tags: tags, itemID: itemID, version: version)
    }

    func tag(_ itemID: String, version: Int64, tags: [String]) async throws -> Int64 {
        try await api.itemTag(itemID, version: version, tags: tags)
    }

    func putDryRun(itemID: String?, version: Int64?, sensitivity: String?, tags: [String]?) async throws -> JsonObject {
        try await api.itemPutDryRun(itemID: itemID, version: version, sensitivity: sensitivity, tags: tags)
    }

    func sensitivity(_ itemID: String, version: Int64, sensitivity: String, password: String?) async throws -> Int64 {
        try await api.itemSensitivity(itemID, version: version, sensitivity: sensitivity, password: password)
    }

    func delete(_ itemID: String, password: String?) async throws { try await api.itemDelete(itemID, password: password) }
}
