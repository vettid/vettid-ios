import Foundation
import VettIDData

/// A small dialog of the add/edit screen. Fields are value-first (owner feedback 2026-10-08): each shows one input
/// captioned with its label, and the label and type change through these dialogs. Mirrors vettid-android `EditDialog`.
public enum EditDialog: Equatable, Sendable {
    /// "Add a field": what it is called and its type, before it is added.
    case addField(label: String = "", kind: String = FieldKinds.text)
    case renameField(index: Int, label: String)
    /// Only for a field not yet saved (a saved field keeps its kind, §10.7).
    case fieldKind(index: Int, kind: String)
    /// A member-defined category (§10.7): the typed name; the identifier is derived from it.
    case newCategory(name: String = "")
}

/// Where on the editor a problem is shown: under the name, under a field, under the notes, or in the list of the others.
public enum ProblemPlace: Hashable, Sendable {
    case name, field(Int), notes, summary

    /// The name's problems, shown under the name.
    public static let nameProblems: Set<DraftProblem> = [.nameEmpty, .nameTooLong]
    /// The item's problems shown in place (the name's, the notes'); the rest are listed together.
    public static let inline: Set<DraftProblem> = nameProblems.union([.notesTooLong])
}

/// The add/edit screen's state; never printed or reflected with its values. Mirrors vettid-android `ItemEditUiState`.
public struct ItemEditState: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var itemID: String?
    public var draft = ItemDraft()
    public var check = DraftCheck()
    public var version: Int64 = 0
    public var loading = false
    /// Problems are shown once the member tried to save.
    public var showErrors = false
    public var busy = false
    public var prompt: PasswordPrompt?
    public var error: FailureKind?
    public var errorCode: String?
    /// The limit a `limit` error named (VAULT-MESSAGING 0.21.0 §10.1); nil from an older vault.
    public var limit: VaultLimit?
    public var tagInput = ""
    public var dirty = false
    public var confirmDiscard = false
    /// Set when saved: the item to show.
    public var savedID: String?
    /// What saving does to sharing with the tags as they are now: the vault's dry run (§10.7, 0.21.0), or for an older
    /// vault the share rules the item newly matches.
    public var shareImpact: [ShareImpact] = []
    public var dialog: EditDialog?
    /// The field whose value input takes the focus (once: just added).
    public var focusField: Int?
    /// The member's own categories in their vault (distinct, sorted), offered after the recommended ones.
    public var customCategories: [String] = []
    /// The template's name, shown as the name's placeholder (owner request 2026-10-08: no pre-typed example text); the item
    /// is saved under it when the name is left empty. Nil for a blank item and an existing one.
    public var nameHint: String?
    /// An existing item's new protection, picked here (`item.sensitivity` after the content is saved); nil: unchanged.
    public var protectionTo: Sensitivity?
    /// Leaving `critical` warns first (§10.7), as on the item's screen.
    public var confirmLeaveCritical = false
    /// The content was saved but the protection change was refused: the editor shows the item as saved.
    public var savedButProtection = false
    /// Counts the saves refused for the draft's problems: each one takes the member to the first problem (I4 audit,
    /// accessibility).
    public var refusedSaves = 0

    public init(itemID: String? = nil) { self.itemID = itemID }

    public var isNew: Bool { itemID == nil }

    /// The protection the item will have once saved.
    public var protection: Sensitivity { protectionTo ?? draft.sensitivity }

    /// The custom categories the picker lists: the member's own, and this item's when it is a custom one.
    public var pickerCustoms: [String] { ItemCategories.customs(customCategories + [draft.category]) }

    /// Whether the item carries the reserved `@profile` tag (connections see it in the shared profile, §10.8).
    public var inProfile: Bool { draft.tags.contains(ItemChecks.profileTag) }

    /// The name the password step shows: the typed one, else the template's, else "This item".
    public var shownName: String {
        let n = draft.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (nameHint ?? ItemsStrings.unnamed) : draft.name
    }

    /// The protection section's note: why `@profile` keeps it standard, or the change saving makes.
    public var protectionNote: String? {
        if inProfile && protection == .data { return ItemsStrings.protectionProfile }
        guard protectionTo != nil else { return nil }
        return ItemsStrings.protectionChange(ItemsText.sensitivity(draft.sensitivity), ItemsText.sensitivity(protection))
    }

    /// Where the first problem shown is, in the form's order: the name, a field, the notes, then the list of the others.
    public var firstProblem: ProblemPlace? {
        guard showErrors else { return nil }
        let p = check.problems
        if !p.isDisjoint(with: ProblemPlace.nameProblems) { return .name }
        if let i = check.fieldProblems.filter({ !$0.value.isEmpty }).keys.min() { return .field(i) }
        if p.contains(.notesTooLong) { return .notes }
        return p.subtracting(ProblemPlace.inline).isEmpty ? nil : .summary
    }

    /// How many problems are shown: the name's, each field's, the notes' and the others in the list.
    public var problemCount: Int {
        let p = check.problems
        let name = p.isDisjoint(with: ProblemPlace.nameProblems) ? 0 : 1
        let notes = p.contains(.notesTooLong) ? 1 : 0
        return name + notes + check.fieldProblems.values.reduce(0) { $0 + $1.count } + p.subtracting(ProblemPlace.inline).count
    }

    public var description: String { "ItemEditState(\(itemID ?? "new"), busy: \(busy), error: \(error.map { "\($0)" } ?? "nil"))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
