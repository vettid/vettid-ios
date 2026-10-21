import Foundation
import VettIDCrypto

/// Where the vault keeps an item (VAULT-MESSAGING §10.7, VAULT-ITEMS §4): ``data`` in DEK state, values in `item.get`;
/// ``secret`` in DEK state, values only through `item.reveal` (audited); ``critical`` inside the Protean Credential, every
/// read or change a credential operation with the password. The interface calls the three "Standard", "Secret" and
/// "Critical". Mirrors vettid-android `Sensitivity`.
public enum Sensitivity: String, CaseIterable, Sendable, Codable {
    case data
    case secret
    case critical

    public var wire: String { rawValue }

    /// An unknown value (a newer vault) is treated as ``secret``: its values stay hidden until revealed on purpose.
    public static func of(_ wire: String?) -> Sensitivity {
        guard let wire else { return .data }
        return Sensitivity(rawValue: wire) ?? .secret
    }
}

/// The field kinds of §10.7; `file` is reserved (files later) and refused by the vault. Mirrors vettid-android
/// `FieldKinds`.
public enum FieldKinds {
    public static let text = ItemSpec.kindText
    public static let multiline = ItemSpec.kindMultiline
    public static let number = ItemSpec.kindNumber
    public static let date = ItemSpec.kindDate
    public static let email = ItemSpec.kindEmail
    public static let phone = ItemSpec.kindPhone
    public static let url = ItemSpec.kindURL
    public static let password = ItemSpec.kindPassword
    public static let otp = ItemSpec.kindOTP
    public static let address = ItemSpec.kindAddress
    /// Reserved for files later (§10.7, still in 0.21.0): never offered, and refused before anything is sent.
    public static let file = ItemSpec.kindFile

    /// The kinds a member can choose, in the order the add-field menu offers them (never ``file``).
    public static let choosable = [text, multiline, password, number, date, email, phone, url, otp, address]

    /// Kinds the apps mask and reveal on purpose (§10.7: `password`; an `otp` seed is a secret too).
    public static func masked(_ kind: String) -> Bool { kind == password || kind == otp }

    /// Kinds whose value may span lines.
    public static func multiline(_ kind: String) -> Bool { kind == multiline || kind == password }
}

/// An `address` value (§10.7): members of at most 256 bytes; [country] an ISO 3166-1 alpha-2 code in upper case. Never
/// printed or reflected. Mirrors vettid-android `AddressValue`.
public struct AddressValue: Equatable, Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    public var street = ""
    public var street2 = ""
    public var city = ""
    public var region = ""
    public var postalCode = ""
    public var country = ""

    public init(
        street: String = "", street2: String = "", city: String = "", region: String = "", postalCode: String = "",
        country: String = ""
    ) {
        self.street = street
        self.street2 = street2
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
    }

    public var isEmpty: Bool { parts.allSatisfy { $0.value.isEmpty } }

    /// The members in the order the vault encodes them, with their wire names.
    public var parts: [(name: String, value: String)] {
        [("street", street), ("street2", street2), ("city", city), ("region", region), ("postal_code", postalCode), ("country", country)]
    }

    /// For display: the non-empty lines (the city line joins postal code, city and region).
    public var lines: [String] {
        let blank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty }
        let cityLine = [postalCode, city, region].filter { !blank($0) }.joined(separator: " ")
        return [street, street2, cityLine, country].filter { !blank($0) }
    }

    public static func of(_ parts: [String: String]) -> AddressValue {
        AddressValue(
            street: parts["street"] ?? "", street2: parts["street2"] ?? "", city: parts["city"] ?? "",
            region: parts["region"] ?? "", postalCode: parts["postal_code"] ?? "", country: parts["country"] ?? ""
        )
    }

    public var description: String { "AddressValue(…)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A field's value: a string (every kind but `address`) or an address. Never printed or reflected. Mirrors vettid-android
/// `FieldValue`.
public enum FieldValue: Equatable, Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    case text(String)
    case address(AddressValue)

    public var isEmpty: Bool {
        switch self {
        case .text(let s): s.isEmpty
        case .address(let a): a.isEmpty
        }
    }

    public var description: String {
        switch self {
        case .text: "Text(…)"
        case .address: "Address(…)"
        }
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One field as the app shows it. [value] nil: not revealed (a `secret` or `critical` item's values, §10.7). Mirrors
/// vettid-android `ItemFieldView`.
public struct ItemFieldView: Equatable, Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    public var fieldID: String?
    public var label: String
    public var kind: String
    public var value: FieldValue?

    public init(fieldID: String?, label: String, kind: String, value: FieldValue? = nil) {
        self.fieldID = fieldID
        self.label = label
        self.kind = kind
        self.value = value
    }

    public var description: String { "ItemFieldView(\(fieldID ?? "new"), \(kind))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// An item in the list (`item.list`: metadata, never values or notes). Mirrors vettid-android `ItemSummary`.
public struct ItemSummary: Equatable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    public var itemID: String
    public var version: Int64
    public var name: String
    public var category: String
    public var sensitivity: Sensitivity
    public var template: String?
    public var tags: [String]
    /// The fields' labels, in order (shown as the row's second line).
    public var labels: [String]
    public var updatedAt: Date?

    public init(
        itemID: String, version: Int64, name: String, category: String, sensitivity: Sensitivity, template: String? = nil,
        tags: [String] = [], labels: [String] = [], updatedAt: Date? = nil
    ) {
        self.itemID = itemID
        self.version = version
        self.name = name
        self.category = category
        self.sensitivity = sensitivity
        self.template = template
        self.tags = tags
        self.labels = labels
        self.updatedAt = updatedAt
    }

    public var id: String { itemID }
    public var description: String { "ItemSummary(\(itemID), v\(version), \(sensitivity.wire))" }
}

/// An item with its fields (§10.7). A `data` item comes with its values; a `secret` or `critical` item without them
/// ([revealed] false, every value nil, [notes] nil and [hasNotes] telling whether there are notes) until the member
/// reveals it on purpose. [size] is the item's size as the vault counts it (`item.get`'s `size`, 0.21.0), for the room
/// left when the values are not at hand; nil from an older vault, or for a critical item not written since its upgrade.
/// Never printed or reflected with its values. Mirrors vettid-android `ItemDetail`.
public struct ItemDetail: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var itemID: String
    public var version: Int64
    public var name: String
    public var category: String
    public var sensitivity: Sensitivity
    public var template: String?
    public var tags: [String]
    public var fields: [ItemFieldView]
    public var notes: String?
    public var hasNotes: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var revealed: Bool
    public var size: Int?

    /// [revealed] nil: a `data` item is, any other is not.
    public init(
        itemID: String, version: Int64, name: String, category: String, sensitivity: Sensitivity, template: String? = nil,
        tags: [String] = [], fields: [ItemFieldView] = [], notes: String? = nil, hasNotes: Bool = false, createdAt: Date? = nil,
        updatedAt: Date? = nil, revealed: Bool? = nil, size: Int? = nil
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
        self.revealed = revealed ?? (sensitivity == .data)
        self.size = size
    }

    public var summary: ItemSummary {
        ItemSummary(
            itemID: itemID, version: version, name: name, category: category, sensitivity: sensitivity, template: template,
            tags: tags, labels: fields.map(\.label), updatedAt: updatedAt
        )
    }

    /// The same item without its values, as `item.get` gives a secret or critical one (what a screen keeps when it hides
    /// them).
    public func hidden() -> ItemDetail {
        guard sensitivity != .data else { return self }
        var h = self
        h.fields = fields.map { var f = $0; f.value = nil; return f }
        h.hasNotes = hasNotes || !(notes ?? "").isEmpty
        h.notes = nil
        h.revealed = false
        return h
    }

    public var description: String { "ItemDetail(\(itemID), v\(version), \(sensitivity.wire), revealed: \(revealed))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The member's choice of what the Vault list shows (all on this phone: the list holds every item's metadata). Mirrors
/// vettid-android `ItemFilter`.
public struct ItemFilter: Equatable, Sendable {
    public var query: String
    public var tag: String?
    public var category: String?
    public var sensitivity: Sensitivity?

    public init(query: String = "", tag: String? = nil, category: String? = nil, sensitivity: Sensitivity? = nil) {
        self.query = query
        self.tag = tag
        self.category = category
        self.sensitivity = sensitivity
    }

    public var isEmpty: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && tag == nil && category == nil && sensitivity == nil }

    public func matches(_ i: ItemSummary) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        let has = { (s: String) in s.range(of: q, options: .caseInsensitive) != nil }
        return (tag.map { i.tags.contains($0) } ?? true) && (category.map { i.category == $0 } ?? true)
            && (sensitivity.map { i.sensitivity == $0 } ?? true) && (q.isEmpty || has(i.name) || i.tags.contains(where: has))
    }

    /// The matching items, by name (case-insensitive), then id.
    public func apply(_ items: [ItemSummary]) -> [ItemSummary] {
        items.filter(matches).sorted { a, b in
            let (x, y) = (a.name.lowercased(), b.name.lowercased())
            return x == y ? ItemSpec.utf8Less(a.itemID, b.itemID) : ItemSpec.utf8Less(x, y)
        }
    }
}

/// Whether the item list has been read since the vault opened. Mirrors vettid-android `ListLoad`.
public enum ListLoad: Sendable {
    case notLoaded, loading, loaded, failed
}
