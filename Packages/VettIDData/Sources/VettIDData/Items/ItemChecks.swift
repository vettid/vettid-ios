import Foundation
import VettIDCrypto

/// The checks of VAULT-MESSAGING §10.7 and §10.8 on what the member typed, and the size of the item it would become.
/// Mirrors vettid-android `ItemChecks`.
public enum ItemChecks {
    public static let maxName = ItemSpec.maxName
    public static let maxLabel = ItemSpec.maxLabel
    public static let maxValue = ItemSpec.maxValue
    public static let maxNotes = ItemSpec.maxNotes
    public static let maxFields = ItemSpec.maxFields
    public static let maxTags = ItemSpec.maxTags
    public static let maxItemBytes = ItemSpec.maxItemBytes
    public static let maxCriticalBytes = ItemSpec.maxCriticalBytes
    public static let maxAddressPart = ItemSpec.maxAddressPart
    public static let profileTag = ItemSpec.profileTag
    /// A vault holds at most 2,000 items, critical ones included, and at most 1,000 critical items (§10.7).
    public static let maxItems = 2_000
    public static let maxCriticalItems = 1_000
    /// At most 32 items carry `@profile` (§10.8).
    public static let maxProfileItems = 32

    public static var recommendedCategories: [String] { ItemSpec.recommendedCategories }

    private static func bytes(_ s: String) -> Int { s.utf8.count }

    public static func isValidCategory(_ s: String) -> Bool { ItemSpec.isValidCategory(s) }

    /// The tag as the vault stores it (§10.8: trimmed, lower case, single spaces), or nil if it is not one; `@profile` is
    /// reserved.
    public static func normalizeTag(_ s: String, reserved: Bool = true) -> String? {
        try? ItemSpec.normalizeTag(s, reserved: reserved)
    }

    /// Normalised, sorted and without duplicates; nil if any tag is invalid or there are more than 16.
    public static func normalizeTags(_ tags: [String]) -> [String]? {
        var out = Set<String>()
        for t in tags where !t.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let n = normalizeTag(t) else { return nil }
            out.insert(n)
        }
        return out.count <= maxTags ? out.sorted(by: ItemSpec.utf8Less) : nil
    }

    /// The problems of one value of [kind] (an address checks each member; `file` is reserved, §10.7).
    public static func valueProblems(_ kind: String, _ v: FieldValue) -> Set<DraftProblem> {
        if kind == FieldKinds.file { return [.valueInvalid] }
        switch v {
        case .address(let a): return addressProblems(a)
        case .text(let s):
            if kind == FieldKinds.address { return [.valueInvalid] }
            if bytes(s) > maxValue { return [.valueTooLong] }
            if !ItemSpec.isCleanText(s, multi: FieldKinds.multiline(kind)) { return [.badCharacter] }
            // A kind this app does not know is kept as the member typed it; the vault decides.
            if !ItemSpec.isValidKind(kind) { return [] }
            return ItemSpec.isValidStringValue(kind, s) ? [] : [.valueInvalid]
        }
    }

    private static func addressProblems(_ a: AddressValue) -> Set<DraftProblem> {
        var out = Set<DraftProblem>()
        for (name, s) in a.parts {
            if bytes(s) > maxAddressPart { out.insert(.valueTooLong) }
            if !ItemSpec.isCleanText(s, multi: false) { out.insert(.badCharacter) }
            if name == "country", !s.isEmpty, !ItemSpec.isCountryCode(s) { out.insert(.valueInvalid) }
        }
        return out
    }

    public static func labelProblems(_ label: String) -> Set<DraftProblem> {
        if label.isEmpty { return [.labelEmpty] }
        if bytes(label) > maxLabel { return [.labelTooLong] }
        return ItemSpec.isCleanText(label, multi: false) ? [] : [.badCharacter]
    }

    /// Everything the vault would refuse about [d] (§10.7, §10.8), and its size.
    public static func check(_ d: ItemDraft) -> DraftCheck {
        var problems = itemProblems(d)
        let tags = normalizeTags(d.tags)
        if tags == nil, d.tags.count(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) > maxTags {
            problems.insert(.tooManyTags)
        } else if tags == nil {
            problems.insert(.tagInvalid)
        } else if tags?.contains(profileTag) == true, d.sensitivity != .data {
            problems.insert(.profileNotData)
        }
        var fieldProblems: [Int: Set<DraftProblem>] = [:]
        for (i, f) in d.fields.enumerated() {
            // A kept value was checked by the vault for its kind (§10.7 Kept values); a kept file field cannot exist.
            let value = f.kept && f.kind != FieldKinds.file ? [] : valueProblems(f.kind, f.value)
            let all = labelProblems(f.label.itemTrimmed).union(value)
            if !all.isEmpty { fieldProblems[i] = all }
        }
        let max = d.sensitivity == .critical ? maxCriticalBytes : maxItemBytes
        let visible = visibleSize(d, tags: tags ?? [])
        var c = sized(d, visible: visible)
        // An inexact size is an upper bound: only what is certain (the values at hand) refuses the draft.
        if (c.exact ? c.size : visible) > max { problems.insert(.tooLarge) }
        c.problems = problems
        c.fieldProblems = fieldProblems
        c.tags = tags
        c.maxSize = max
        return c
    }

    private static func itemProblems(_ d: ItemDraft) -> Set<DraftProblem> {
        var problems = Set<DraftProblem>()
        let name = d.name.itemTrimmed
        if name.isEmpty {
            problems.insert(.nameEmpty)
        } else if bytes(name) > maxName {
            problems.insert(.nameTooLong)
        } else if !ItemSpec.isCleanText(name, multi: false) {
            problems.insert(.badCharacter)
        }
        if !isValidCategory(d.category) { problems.insert(.categoryInvalid) }
        if bytes(d.notes) > maxNotes {
            problems.insert(.notesTooLong)
        } else if !ItemSpec.isCleanText(d.notes, multi: true) {
            problems.insert(.badCharacter)
        }
        if d.fields.count > maxFields { problems.insert(.tooManyFields) }
        return problems
    }

    /// The size with the kept values counted from the stored size, whether it is exact, and whether it is known.
    private static func sized(_ d: ItemDraft, visible: Int) -> DraftCheck {
        guard d.keeps else { return DraftCheck(size: visible) }
        guard let base = d.base, let kept = base.bytes else { return DraftCheck(size: visible, exact: false, sizeKnown: false) }
        let keptIDs = Set(d.fields.filter(\.kept).compactMap(\.fieldID))
        return DraftCheck(size: visible + kept, exact: keptIDs == base.fieldIDs && d.keepNotes == base.notes)
    }

    /// The item's size as the vault counts it (§10.7 Size, 0.21.0): the length of its content encoding, without the members
    /// the vault assigns (`item_id`, `version`, the times and the field ids). Exact for a draft that holds every value; a
    /// kept value counts as empty here (``check(_:)`` adds what the stored size says it holds).
    ///
    /// `{"name":…,"category":…,"sensitivity":…[,"template":…],"tags":[…],"fields":[{"label":…,"kind":…,"value":…},…][,"notes":…]}`
    public static func visibleSize(_ d: ItemDraft, tags: [String]) -> Int {
        let b = JsonBuilder().string("name", d.name.itemTrimmed).string("category", d.category).string("sensitivity", d.sensitivity.wire)
        if let t = d.template { b.string("template", t) }
        b.raw("tags", JsonBuilder.array(tags.map(JsonBuilder.quote)))
        let fields = d.fields.map { f in
            JsonBuilder().string("label", f.label.itemTrimmed).string("kind", f.kind).raw("value", valueJSON(f.value)).build()
        }
        b.raw("fields", JsonBuilder.array(fields))
        if !d.keepNotes, !d.notes.isEmpty { b.string("notes", d.notes) }
        return b.bytes().count
    }

    /// A value's JSON as the vault keeps it: a string, or an address object with its non-empty members in fixed order.
    public static func valueJSON(_ v: FieldValue) -> String {
        switch v {
        case .text(let s): return JsonBuilder.quote(s)
        case .address(let a):
            let b = JsonBuilder()
            for (name, s) in a.parts where !s.isEmpty { b.string(name, s) }
            return b.build()
        }
    }
}

extension String {
    /// Without leading and trailing white space, as Kotlin's `trim()` (the names and labels the member typed).
    var itemTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
