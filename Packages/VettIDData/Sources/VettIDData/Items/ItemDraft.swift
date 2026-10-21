import Foundation
import VettIDCrypto

/// One field being edited: an existing field ([fieldID] set) or a new one. Address kinds use [address], the rest [text].
/// [kept]: the field's stored value is not at hand (a `secret` or `critical` item, VAULT-MESSAGING 0.21.0 §10.7 Kept
/// values) and the vault keeps it; the field is sent without `value` until the member types into it. [monthYear]: how a
/// `date` is entered, never sent: as a month and year (`YYYY-MM`, which §10.7 allows), e.g. a card's expiry. Never
/// printed or reflected with its value. Mirrors vettid-android `DraftField`.
public struct DraftField: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var fieldID: String?
    public var label: String
    public var kind: String
    public var text: String
    public var address: AddressValue
    public var kept: Bool
    public var monthYear: Bool

    public init(
        fieldID: String? = nil, label: String, kind: String, text: String = "", address: AddressValue = AddressValue(),
        kept: Bool = false, monthYear: Bool = false
    ) {
        self.fieldID = fieldID
        self.label = label
        self.kind = kind
        self.text = text
        self.address = address
        self.kept = kept
        self.monthYear = monthYear
    }

    public var value: FieldValue { kind == FieldKinds.address ? .address(address) : .text(text) }

    /// `YYYY-MM`.
    static let yearMonthLength = 7

    public static func of(_ f: ItemFieldView) -> DraftField {
        switch f.value {
        case .address(let a): DraftField(fieldID: f.fieldID, label: f.label, kind: f.kind, address: a)
        case .text(let t):
            DraftField(
                fieldID: f.fieldID, label: f.label, kind: f.kind, text: t,
                monthYear: f.kind == FieldKinds.date && t.count == yearMonthLength
            )
        case nil: DraftField(fieldID: f.fieldID, label: f.label, kind: f.kind, kept: f.fieldID != nil)
        }
    }

    public var description: String { "DraftField(\(fieldID ?? "new"), \(kind)\(kept ? ", kept" : ""))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What an edit of an item without its values started from (§10.7 Kept values): the ids of the fields whose values the
/// vault keeps, whether it keeps notes, and the bytes those values and notes add to the item's size ([bytes]: `item.get`'s
/// `size` less the metadata's; nil when the vault gave no `size`). Mirrors vettid-android `KeptBase`.
public struct KeptBase: Equatable, Sendable {
    public var fieldIDs: Set<String>
    public var notes: Bool
    public var bytes: Int?

    public init(fieldIDs: Set<String>, notes: Bool, bytes: Int?) {
        self.fieldIDs = fieldIDs
        self.notes = notes
        self.bytes = bytes
    }
}

/// An item as the member edits it (§10.7): created from a template or blank, or from an item's content. A `data` item (or
/// a revealed one) is edited with its values; a `secret` or `critical` one with its stored values kept ([kept] fields,
/// [keepNotes]): editing never reveals them. [tags] are as typed; ``ItemChecks`` normalises them. Never printed or
/// reflected with its values. Mirrors vettid-android `ItemDraft`.
public struct ItemDraft: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var name: String
    public var category: String
    public var template: String?
    public var sensitivity: Sensitivity
    public var tags: [String]
    public var fields: [DraftField]
    public var notes: String
    /// The stored notes are kept (`keep_notes`, §10.7); [notes] is then empty.
    public var keepNotes: Bool
    public var base: KeptBase?

    public init(
        name: String = "", category: String = "other", template: String? = nil, sensitivity: Sensitivity = .data,
        tags: [String] = [], fields: [DraftField] = [], notes: String = "", keepNotes: Bool = false, base: KeptBase? = nil
    ) {
        self.name = name
        self.category = category
        self.template = template
        self.sensitivity = sensitivity
        self.tags = tags
        self.fields = fields
        self.notes = notes
        self.keepNotes = keepNotes
        self.base = base
    }

    /// Whether anything is sent as kept (a field without `value`, or `keep_notes`).
    public var keeps: Bool { keepNotes || fields.contains(where: \.kept) }

    /// The draft of an item: with its values when they are at hand (a `data` item, or a revealed one), else with every
    /// stored value and the notes kept, and the bytes they add from the item's ``ItemDetail/size``.
    public static func of(_ d: ItemDetail) -> ItemDraft {
        var draft = ItemDraft(
            name: d.name, category: d.category, template: d.template, sensitivity: d.sensitivity, tags: d.tags,
            fields: d.fields.map(DraftField.of), notes: d.notes ?? "", keepNotes: !d.revealed && d.hasNotes
        )
        guard draft.keeps else { return draft }
        let ids = Set(draft.fields.filter(\.kept).compactMap(\.fieldID))
        let bytes = d.size.map { max($0 - ItemChecks.visibleSize(draft, tags: d.tags), 0) }
        draft.base = KeptBase(fieldIDs: ids, notes: draft.keepNotes, bytes: bytes)
        return draft
    }

    public var description: String { "ItemDraft(\(sensitivity.wire), \(fields.count) fields)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What is wrong with a draft, before anything is sent (the vault checks the same, §10.7; it stays the authority).
/// Mirrors vettid-android `DraftProblem`.
public enum DraftProblem: Hashable, Sendable, CaseIterable {
    case nameEmpty
    case nameTooLong
    case badCharacter
    case categoryInvalid
    case labelEmpty
    case labelTooLong
    case valueInvalid
    case valueTooLong
    case notesTooLong
    case tooManyFields
    case tooManyTags
    case tagInvalid
    /// `@profile` is allowed only on `data` items (§10.8).
    case profileNotData
    /// The item's size (§10.7 Size) would exceed 65,536 bytes (12,288 for a critical item).
    case tooLarge
}

/// A draft's check: [problems] of the item, [fieldProblems] by field index, the normalised [tags] (nil when a tag is
/// invalid), and the item's [size] as the vault counts it (§10.7 Size, 0.21.0). [exact] is false when kept values are
/// counted from the stored size but some of them left (removed or replaced fields, notes): [size] is then an upper bound;
/// [sizeKnown] is false when the vault gave no stored size (only the values at hand are counted). Mirrors vettid-android
/// `DraftCheck`.
public struct DraftCheck: Equatable, Sendable {
    public var problems: Set<DraftProblem> = []
    public var fieldProblems: [Int: Set<DraftProblem>] = [:]
    public var tags: [String]? = []
    public var size = 0
    public var maxSize = ItemSpec.maxItemBytes
    public var exact = true
    public var sizeKnown = true

    public init(
        problems: Set<DraftProblem> = [], fieldProblems: [Int: Set<DraftProblem>] = [:], tags: [String]? = [], size: Int = 0,
        maxSize: Int = ItemSpec.maxItemBytes, exact: Bool = true, sizeKnown: Bool = true
    ) {
        self.problems = problems
        self.fieldProblems = fieldProblems
        self.tags = tags
        self.size = size
        self.maxSize = maxSize
        self.exact = exact
        self.sizeKnown = sizeKnown
    }

    public var ok: Bool { problems.isEmpty && fieldProblems.isEmpty }

    /// The room left before the size limit; nil when the size is not known.
    public var roomLeft: Int? { sizeKnown ? maxSize - size : nil }
}
