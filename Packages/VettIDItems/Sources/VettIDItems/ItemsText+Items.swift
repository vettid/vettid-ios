import Foundation
import VettIDData

// The member-facing names of sensitivities, kinds and categories, and the item screens' messages. Mirrors vettid-android
// `ItemsText` and the item screens' text helpers (`impactText`, `SizeNote`).
public extension ItemsText {
    static func sensitivity(_ s: Sensitivity) -> String {
        switch s {
        case .data: ItemsStrings.sensitivityData
        case .secret: ItemsStrings.sensitivitySecret
        case .critical: ItemsStrings.sensitivityCritical
        }
    }

    static func sensitivityNote(_ s: Sensitivity) -> String {
        switch s {
        case .data: ItemsStrings.sensitivityDataNote
        case .secret: ItemsStrings.sensitivitySecretNote
        case .critical: ItemsStrings.sensitivityCriticalNote
        }
    }

    /// One label per kind; a kind this app does not know reads "Other".
    static func kind(_ kind: String) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch kind {
        case FieldKinds.text: ItemsStrings.kindText
        case FieldKinds.multiline: ItemsStrings.kindMultiline
        case FieldKinds.number: ItemsStrings.kindNumber
        case FieldKinds.date: ItemsStrings.kindDate
        case FieldKinds.email: ItemsStrings.kindEmail
        case FieldKinds.phone: ItemsStrings.kindPhone
        case FieldKinds.url: ItemsStrings.kindUrl
        case FieldKinds.password: ItemsStrings.kindPassword
        case FieldKinds.otp: ItemsStrings.kindOtp
        case FieldKinds.address: ItemsStrings.kindAddress
        default: ItemsStrings.kindOther
        }
    }

    /// A field's kind as its hint says it: a month-and-year `date` as such.
    static func kindName(_ f: DraftField) -> String {
        f.kind == FieldKinds.date && f.monthYear ? ItemsStrings.kindMonthYear : kind(f.kind)
    }

    /// What a value of [kind] must look like, for an invalid one (§10.7); [monthYear]: a date entered as a month and year.
    static func kindRule(_ kind: String, monthYear: Bool = false) -> String {
        switch kind {
        case FieldKinds.number: ItemsStrings.ruleNumber
        // A month-and-year field names its own form for any invalid value, a full date included (VAULT-MESSAGING 0.55.5 §10.7).
        case FieldKinds.date: monthYear ? ItemsStrings.ruleMonth : ItemsStrings.ruleDate
        case FieldKinds.email: ItemsStrings.ruleEmail
        case FieldKinds.phone: ItemsStrings.rulePhone
        case FieldKinds.url: ItemsStrings.ruleUrl
        case FieldKinds.otp: ItemsStrings.ruleOtp
        case FieldKinds.address: ItemsStrings.ruleAddress
        default: ItemsStrings.ruleText
        }
    }

    /// A field's message: a label's problem first, then the value's; a value that is not (yet) one of its kind says its
    /// rule while typing, and so does a full date in a month field (VAULT-MESSAGING 0.55.5 §10.7).
    static func fieldError(_ field: DraftField, problems: Set<DraftProblem>) -> String? {
        let labelProblem = [DraftProblem.labelEmpty, .labelTooLong].first { problems.contains($0) }
            ?? (problems.contains(.badCharacter) && !ItemChecks.labelProblems(field.label.trimmingCharacters(in: .whitespaces)).isEmpty
                ? .badCharacter : nil)
        if let labelProblem { return problem(labelProblem) }
        let valueProblem = problems.subtracting([.labelEmpty, .labelTooLong]).sorted { "\($0)" < "\($1)" }.first
        let month = field.kind == FieldKinds.date && field.monthYear
        let invalid = (month && field.text.utf8.count > DraftField.yearMonthLength) || FieldInput.incomplete(field.kind, field.text)
        let live: DraftProblem? = !field.kept && invalid ? .valueInvalid : nil
        guard let p = valueProblem ?? live else { return nil }
        return p == .valueInvalid ? kindRule(field.kind, monthYear: field.monthYear) : problem(p, kind: field.kind)
    }

    /// A category as shown: a recommended one's label, a member-defined one humanized.
    static func category(_ id: String) -> String { ItemTemplates.category(id)?.label ?? ItemTemplates.customLabel(id) }

    /// The message of one draft problem ([kind]: the field's, for an invalid value).
    static func problem(_ p: DraftProblem, kind: String = FieldKinds.text) -> String { // swiftlint:disable:this cyclomatic_complexity
        switch p {
        case .nameEmpty: ItemsStrings.problemNameEmpty
        case .nameTooLong: ItemsStrings.problemNameLong
        case .badCharacter: ItemsStrings.problemBadCharacter
        case .categoryInvalid: ItemsStrings.problemCategory
        case .labelEmpty: ItemsStrings.problemLabelEmpty
        case .labelTooLong: ItemsStrings.problemLabelLong
        case .valueInvalid: kindRule(kind)
        case .valueTooLong: ItemsStrings.problemValueLong
        case .notesTooLong: ItemsStrings.problemNotesLong
        case .tooManyFields: ItemsStrings.problemFields
        case .tooManyTags: ItemsStrings.problemTags
        case .tagInvalid: ItemsStrings.problemTag
        case .profileNotData: ItemsStrings.problemProfile
        case .tooLarge: ItemsStrings.problemSize
        }
    }

    /// A list row's second line: the category, and the sensitivity for a secret or critical item.
    static func rowSupporting(_ i: ItemSummary) -> String {
        let c = category(i.category)
        return i.sensitivity == .data ? c : ItemsStrings.rowSupporting(c, sensitivity(i.sensitivity))
    }

    /// What saving does to sharing with one connection (§10.7 Dry run; §10.12 Overlapping rules). Names are isolated
    /// (bidirectional isolation, as every name next to other text).
    static func impact(_ i: ShareImpact) -> String {
        let who = sharingName(i.connectionName)
        if i.withdrawn { return ItemsStrings.impactWithdrawn(who) }
        if i.usableOnly { return ItemsStrings.impactUsable(who) }
        // 0.23.0: `ask` wins — an `auto` rule asks first while an `ask` rule of the same connection holds the item.
        if let r = i.askRule { return ItemsStrings.impactAskBecause(ruleName(r), who) }
        return i.mode == .auto ? ItemsStrings.impactAuto(who) : ItemsStrings.impactAsk(who)
    }

    /// A rule as the member reads it, by its tags: "your “medical” rule" ("medical + id" for all, "medical or id" for
    /// any). Mirrors vettid-android `ruleName` without the qualifiers the sharing screens add.
    static func ruleName(_ r: ShareRule) -> String {
        ItemsStrings.ruleName(r.tags.joined(separator: r.match == .all ? " + " : " or "))
    }

    /// The room left before the item's size limit (§10.7: 64 KiB, a critical item 12 KiB), once more than three quarters
    /// are used; nil below that or when the size is not known. Kept values count from the vault's `size` (0.21.0); when
    /// some of them leave, the room is "at least" that.
    static func sizeNote(_ c: DraftCheck) -> String? {
        guard let left = c.roomLeft, c.size * 4 >= c.maxSize * 3 else { return nil }
        let kb = 1_024
        if left < 0 { return ItemsStrings.sizeOver((-left + kb - 1) / kb, c.maxSize / kb) }
        return c.exact ? ItemsStrings.sizeLeft(left / kb, c.maxSize / kb) : ItemsStrings.sizeLeftAtLeast(left / kb, c.maxSize / kb)
    }
}

/// A rule the item would gain ([withdrawn] false) or leave ([withdrawn] true) when saved, for one connection
/// ([connectionName] "" before its names arrived); [usableOnly] for a critical item, which a rule makes only usable;
/// [askRule] (0.23.0, §10.12 Overlapping rules) the `ask` rule of the same connection that holds the item, so that saving
/// asks first although this rule is `auto`. Mirrors vettid-android `ShareImpact`.
public struct ShareImpact: Equatable, Sendable {
    public var connectionName: String
    public var mode: ShareMode
    public var usableOnly = false
    public var withdrawn = false
    public var askRule: ShareRule?

    public init(connectionName: String, mode: ShareMode, usableOnly: Bool = false, withdrawn: Bool = false, askRule: ShareRule? = nil) {
        self.connectionName = connectionName
        self.mode = mode
        self.usableOnly = usableOnly
        self.withdrawn = withdrawn
        self.askRule = askRule
    }
}
