import Foundation
import VettIDCrypto

// The member's items (VAULT-MESSAGING §10.7). A `critical` item's forms are credential operations (§3.5.3): the password,
// the item's id and its content sealed to a UTK beside the blob, its values sealed back to a one-time reply key.
extension VaultApi {
    public static let typeItemPut = "item.put"
    public static let typeItemGet = "item.get"
    public static let typeItemReveal = "item.reveal"
    public static let typeItemList = "item.list"
    public static let typeItemTag = "item.tag"
    public static let typeItemSensitivity = "item.sensitivity"
    public static let typeItemDelete = "item.delete"

    private func itemOp(_ type: String, _ b: JsonBuilder) async throws -> JsonObject {
        try StrictJson.parseObject(try await device.op(type, body: b.bytes()))
    }

    private static func tagsJSON(_ tags: [String]) -> String { JsonBuilder.array(tags.map(JsonBuilder.quote)) }

    /// One page of `item.list`, filtered by [tags] (with [match] `any` or `all`), [category] and [sensitivity]. Mirrors
    /// vettid-android `VaultApi.itemList`.
    public func itemList(
        tags: [String]? = nil, match: String? = nil, category: String? = nil, sensitivity: String? = nil, after: String? = nil,
        limit: Int? = nil
    ) async throws -> ItemPage {
        let b = JsonBuilder()
        if let tags { b.raw("tags", Self.tagsJSON(tags)) }
        if let match { b.string("match", match) }
        if let category { b.string("category", category) }
        if let sensitivity { b.string("sensitivity", sensitivity) }
        if let after { b.string("after", after) }
        if let limit { b.uint("limit", UInt64(max(limit, 0))) }
        return ItemPage.of(try await itemOp(Self.typeItemList, b))
    }

    /// `item.get`: a `data` item with its values; a `secret` or `critical` item without them, with `has_notes` and `size`.
    public func itemGet(_ itemID: String) async throws -> Item {
        guard let i = Item.of(try await itemOp(Self.typeItemGet, JsonBuilder().string("item_id", itemID))) else {
            throw VaultStateError(message: "item.get without an item")
        }
        return i
    }

    /// `item.reveal` of a `secret` (or `data`) item: its values, audited (`item.revealed`); [fields] narrows them.
    public func itemReveal(_ itemID: String, fields: [String]? = nil) async throws -> Item {
        let b = JsonBuilder().string("item_id", itemID)
        if let fields { b.raw("fields", Self.tagsJSON(fields)) }
        guard let i = Item.of(try await itemOp(Self.typeItemReveal, b)) else {
            throw VaultStateError(message: "item.reveal without an item")
        }
        return i
    }

    /// `item.reveal` of a `critical` item with the credential password (a credential operation): the plaintext of its
    /// `values_sealed`, `{"fields": [{field_id, value}], "notes"?}`, opened with the request's one-time reply key. The
    /// caller wipes it. The item's id travels sealed too, so that a session attacker cannot redirect the request.
    public func itemRevealCritical(password: String, itemID: String) async throws -> [UInt8] {
        let fields: [SealedField] = [.string("password", password), .string("item_id", itemID)]
        let options = CredOpOptions(outer: [("item_id", itemID)])
        return try await credential.credOpOpening(Self.typeItemReveal, fields, member: "values_sealed", options).opened
    }

    /// Creates ([itemID] nil) or replaces a `data` or `secret` item; [tags] nil leaves them as they are.
    public func itemPut(
        _ content: ItemContent, sensitivity: String? = nil, tags: [String]? = nil, itemID: String? = nil, version: Int64? = nil
    ) async throws -> ItemRef {
        let b = JsonBuilder()
        if let itemID { b.string("item_id", itemID) }
        if let version { b.uint("version", UInt64(max(version, 0))) }
        if let sensitivity { b.string("sensitivity", sensitivity) }
        if let tags { b.raw("tags", Self.tagsJSON(tags)) }
        content.write(b)
        return try ItemRef.of(try await itemOp(Self.typeItemPut, b))
    }

    /// Creates ([itemID] nil) or replaces a `critical` item with the credential password (a credential operation): the
    /// content and the id travel UTK-sealed; only `version` and [tags] are outside (§10.7 "Create and replace").
    public func itemPutCritical(
        password: String, content: ItemContent, tags: [String]? = nil, itemID: String? = nil, version: Int64? = nil
    ) async throws -> ItemRef {
        var fields: [SealedField] = [.string("password", password), .raw("item", content.json())]
        if let itemID { fields.append(.string("item_id", itemID)) }
        var outerRaw: [(String, String)] = []
        if let version { outerRaw.append(("version", String(max(version, 0)))) }
        if let tags { outerRaw.append(("tags", Self.tagsJSON(tags))) }
        let options = CredOpOptions(outer: [("sensitivity", ItemSpec.critical)], outerRaw: outerRaw)
        return try ItemRef.of(StrictJson.parseObject(try await credential.credOp(Self.typeItemPut, fields, options)))
    }

    /// What an `item.put` would do to sharing (§10.7 Dry run, 0.21.0): `{version?, shares, withdrawals}`, changing
    /// nothing. Never carries content: an older vault, which knows no `dry_run`, refuses a put without `name`
    /// (`bad_request`) instead of saving anything.
    public func itemPutDryRun(
        itemID: String? = nil, version: Int64? = nil, sensitivity: String? = nil, tags: [String]? = nil
    ) async throws -> JsonObject {
        let b = JsonBuilder().bool("dry_run", true)
        if let itemID { b.string("item_id", itemID) }
        if let version { b.uint("version", UInt64(max(version, 0))) }
        if let sensitivity { b.string("sensitivity", sensitivity) }
        if let tags { b.raw("tags", Self.tagsJSON(tags)) }
        return try await itemOp(Self.typeItemPut, b)
    }

    /// `item.tag` (no password, for every sensitivity); returns the item's new version.
    public func itemTag(_ itemID: String, version: Int64, tags: [String]) async throws -> Int64 {
        let b = JsonBuilder().string("item_id", itemID).uint("version", UInt64(max(version, 0))).raw("tags", Self.tagsJSON(tags))
        return VaultJSON.int(try await itemOp(Self.typeItemTag, b), "version") ?? 0
    }

    /// `item.sensitivity`: `data` ↔ `secret` is a metadata change; to or from `critical` needs the [password] (a credential
    /// operation, the id also sealed). Returns the item's new version. Apps warn before an item leaves `critical`.
    public func itemSensitivity(_ itemID: String, version: Int64, sensitivity: String, password: String? = nil) async throws -> Int64 {
        guard let password else {
            let b = JsonBuilder().string("item_id", itemID).uint("version", UInt64(max(version, 0))).string("sensitivity", sensitivity)
            return VaultJSON.int(try await itemOp(Self.typeItemSensitivity, b), "version") ?? 0
        }
        let fields: [SealedField] = [.string("password", password), .string("item_id", itemID)]
        let options = CredOpOptions(
            outer: [("item_id", itemID), ("sensitivity", sensitivity)], outerRaw: [("version", String(max(version, 0)))]
        )
        let body = try await credential.credOp(Self.typeItemSensitivity, fields, options)
        return VaultJSON.int(VaultJSON.object(body), "version") ?? 0
    }

    /// `item.delete`; a `critical` item needs the [password] (a credential operation, the id also sealed).
    public func itemDelete(_ itemID: String, password: String? = nil) async throws {
        guard let password else {
            _ = try await itemOp(Self.typeItemDelete, JsonBuilder().string("item_id", itemID))
            return
        }
        let fields: [SealedField] = [.string("password", password), .string("item_id", itemID)]
        _ = try await credential.credOp(Self.typeItemDelete, fields, CredOpOptions(outer: [("item_id", itemID)]))
    }
}
