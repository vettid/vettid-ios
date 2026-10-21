import Foundation
import VettIDCrypto

// Body models of VAULT-MESSAGING §10.7 (items). Read from the strict JSON object of the body; unknown members are ignored
// (§10.1). Never printed or reflected with names or values. Mirrors the item models of vettid-android `Models.kt`.

/// One field of an item (§10.7): [valueJSON] the value's exact JSON text (a string, or an object for an `address`), nil
/// for a hidden value (a `secret` or `critical` item from `item.get`) and, in `item.put`, for a kept one (0.21.0).
public struct ItemField: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let fieldID: String?
    public let label: String
    public let kind: String
    public let valueJSON: String?

    public init(fieldID: String?, label: String, kind: String, valueJSON: String?) {
        self.fieldID = fieldID
        self.label = label
        self.kind = kind
        self.valueJSON = valueJSON
    }

    /// A field of a body; nil without its `label` or `kind`.
    static func of(_ o: JsonObject) -> ItemField? {
        guard let label = VaultJSON.string(o, "label"), let kind = VaultJSON.string(o, "kind") else { return nil }
        return ItemField(fieldID: VaultJSON.string(o, "field_id"), label: label, kind: kind, valueJSON: o["value"]?.raw)
    }

    /// `{field_id?, label, kind, value?}`, the value as given.
    func json() -> String {
        let b = JsonBuilder()
        if let fieldID { b.string("field_id", fieldID) }
        b.string("label", label).string("kind", kind)
        if let valueJSON { b.raw("value", valueJSON) }
        return b.build()
    }

    public var description: String { "ItemField(\(fieldID ?? "new"), \(kind))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// An item (§10.7) as `item.get`, `item.reveal` and `item.list` give it: a `secret` or `critical` item comes without
/// values and notes unless revealed ([hasNotes] then says whether it has notes). [size] is the item's size as the vault
/// counts it (`item.get`, 0.21.0): nil from an older vault, and for a critical item not written or opened since.
public struct Item: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let itemID: String
    public let version: Int64
    public let name: String
    public let category: String
    public let sensitivity: String
    public let template: String?
    public let tags: [String]
    public let fields: [ItemField]
    public let notes: String?
    public let hasNotes: Bool
    public let createdAt: String?
    public let updatedAt: String?
    public let size: Int64?

    public init(
        itemID: String, version: Int64, name: String, category: String = "other", sensitivity: String = "data",
        template: String? = nil, tags: [String] = [], fields: [ItemField] = [], notes: String? = nil, hasNotes: Bool = false,
        createdAt: String? = nil, updatedAt: String? = nil, size: Int64? = nil
    ) {
        self.itemID = itemID
        self.version = version
        self.name = name
        self.category = category
        self.sensitivity = sensitivity
        self.template = template
        self.tags = tags
        self.fields = fields
        self.notes = notes
        self.hasNotes = hasNotes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.size = size
    }

    /// An `<item>`; nil without its `item_id`, `version` or `name`. A missing `category` is `other` and a missing
    /// `sensitivity` `data` (the vault's defaults); a field that cannot be read is left out.
    public static func of(_ o: JsonObject) -> Item? {
        guard let id = VaultJSON.string(o, "item_id"), let version = VaultJSON.int(o, "version"),
              let name = VaultJSON.string(o, "name") else { return nil }
        return Item(
            itemID: id, version: version, name: name, category: VaultJSON.string(o, "category") ?? "other",
            sensitivity: VaultJSON.string(o, "sensitivity") ?? ItemSpec.data, template: VaultJSON.string(o, "template"),
            tags: VaultJSON.strings(o, "tags"), fields: VaultJSON.objects(o, "fields").compactMap(ItemField.of),
            notes: VaultJSON.string(o, "notes"), hasNotes: VaultJSON.bool(o, "has_notes") ?? false,
            createdAt: VaultJSON.string(o, "created_at"), updatedAt: VaultJSON.string(o, "updated_at"),
            size: VaultJSON.int(o, "size")
        )
    }

    public var description: String { "Item(\(itemID), v\(version), \(sensitivity))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What an app writes in `item.put` (§10.7). A field of a replacement without a value keeps its stored value, and
/// [keepNotes] the stored notes (Kept values, 0.21.0); [notes] and [keepNotes] never go together.
public struct ItemContent: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let name: String
    public let category: String?
    public let template: String?
    public let fields: [ItemField]?
    public let notes: String?
    public let keepNotes: Bool

    public init(
        name: String, category: String? = nil, template: String? = nil, fields: [ItemField]? = nil, notes: String? = nil,
        keepNotes: Bool = false
    ) {
        self.name = name
        self.category = category
        self.template = template
        self.fields = fields
        self.notes = notes
        self.keepNotes = keepNotes
    }

    /// Adds the content's members to [b]: `name, category?, template?, fields?, notes?, keep_notes?`.
    func write(_ b: JsonBuilder) {
        b.string("name", name)
        if let category { b.string("category", category) }
        if let template { b.string("template", template) }
        if let fields { b.raw("fields", JsonBuilder.array(fields.map { $0.json() })) }
        if let notes { b.string("notes", notes) }
        if keepNotes { b.bool("keep_notes", true) }
    }

    /// The content as one JSON object (a critical item's sealed `item`).
    func json() -> String {
        let b = JsonBuilder()
        write(b)
        return b.build()
    }

    public var description: String { "ItemContent(\(fields?.count ?? 0) fields)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// `item.put`'s answer (§10.7); for a critical item also the credential's new version.
public struct ItemRef: Equatable, Sendable {
    public let itemID: String
    public let version: Int64
    public let updatedAt: String?
    public let credentialVersion: Int64?

    public init(itemID: String, version: Int64, updatedAt: String? = nil, credentialVersion: Int64? = nil) {
        self.itemID = itemID
        self.version = version
        self.updatedAt = updatedAt
        self.credentialVersion = credentialVersion
    }

    static func of(_ o: JsonObject) throws -> ItemRef {
        guard let id = VaultJSON.string(o, "item_id"), let version = VaultJSON.int(o, "version") else {
            throw VaultStateError(message: "item.put without item_id or version")
        }
        return ItemRef(
            itemID: id, version: version, updatedAt: VaultJSON.string(o, "updated_at"),
            credentialVersion: VaultJSON.int(o, "credential_version")
        )
    }
}

/// One page of `item.list` (§10.7): [next] the cursor of the next page, nil on the last.
public struct ItemPage: Equatable, Sendable {
    public let items: [Item]
    public let next: String?

    public init(items: [Item] = [], next: String? = nil) {
        self.items = items
        self.next = next
    }

    /// `{items, next?}`; an entry that is not an item is left out, and an empty or `null` `next` counts as absent.
    static func of(_ o: JsonObject) -> ItemPage {
        let next = VaultJSON.string(o, "next").flatMap { $0.isEmpty ? nil : $0 }
        return ItemPage(items: VaultJSON.objects(o, "items").compactMap(Item.of), next: next)
    }
}
