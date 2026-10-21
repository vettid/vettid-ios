import Foundation
import Testing
@testable import VettIDData

// Literal encodings are clearer on one line.
// swiftlint:disable line_length

/// The checks of VAULT-MESSAGING §10.7 and §10.8 before anything is sent, and the size the vault counts. Mirrors
/// vettid-android `ItemChecksTest`.
@Suite struct ItemChecksTests {
    func draft(_ fields: DraftField..., s: Sensitivity = .data, tags: [String] = []) -> ItemDraft {
        ItemDraft(name: "Passport", category: "identity_document", sensitivity: s, tags: tags, fields: fields)
    }

    func text(_ kind: String, _ v: String) -> DraftField { DraftField(label: "L", kind: kind, text: v) }

    func problems(_ d: ItemDraft, field i: Int = 0) -> Set<DraftProblem> { ItemChecks.check(d).fieldProblems[i] ?? [] }

    @Test func aTemplateLikeDraftPasses() {
        let c = ItemChecks.check(draft(text("text", "X123"), text("date", "2031-04-30"), text("date", "2031-04")))
        #expect(c.ok && c.tags == [])
    }

    @Test func theNameIsRequiredAndBounded() {
        #expect(ItemChecks.check(ItemDraft(name: "  ")).problems.contains(.nameEmpty))
        #expect(ItemChecks.check(ItemDraft(name: String(repeating: "é", count: 65))).problems.contains(.nameTooLong))
        #expect(ItemChecks.check(ItemDraft(name: "a\u{7}b")).problems.contains(.badCharacter))
        #expect(ItemChecks.check(ItemDraft(name: String(repeating: "x", count: 128))).ok)
    }

    @Test func valuesFollowTheirKind() {
        func bad(_ kind: String, _ v: String) -> Bool { problems(draft(text(kind, v))).contains(.valueInvalid) }
        #expect(bad("number", "1,5") && !bad("number", "-3.25"))
        #expect(bad("date", "2031-02-30") && bad("date", "30.04.2031"))
        #expect(bad("email", "no-at-sign") && !bad("email", "a@b"))
        #expect(bad("phone", "call me") && !bad("phone", "+49 (30) 123-45.6"))
        #expect(bad("url", "example.com") && !bad("url", "https://example.com/x"))
        #expect(bad("otp", "short") && !bad("otp", "JBSWY3DPEHPK3PXP"))
        // Every kind accepts "" (not filled in).
        for kind in ["number", "date", "email", "phone", "url", "otp"] { #expect(!bad(kind, ""), "\(kind)") }
    }

    @Test func lineBreaksOnlyWhereTheKindAllowsThem() {
        #expect(problems(draft(text("text", "a\nb"))).contains(.badCharacter))
        #expect(ItemChecks.check(draft(text("multiline", "a\nb\tc"))).ok)
        #expect(ItemChecks.check(draft(text("password", "a\nb"))).ok)
    }

    @Test func anAddressNeedsAnUpperCaseCountryCode() {
        let ok = DraftField(label: "Address", kind: "address", address: AddressValue(city: "Berlin", country: "DE"))
        #expect(ItemChecks.check(draft(ok)).ok)
        var lower = ok
        lower.address.country = "de"
        #expect(problems(draft(lower)).contains(.valueInvalid))
        var long = ok
        long.address.street = String(repeating: "x", count: 257)
        #expect(problems(draft(long)).contains(.valueTooLong))
    }

    @Test func labelsAreRequiredAndAtMost64Bytes() {
        let c = ItemChecks.check(draft(DraftField(label: "", kind: "text"), DraftField(label: String(repeating: "x", count: 65), kind: "text")))
        #expect(c.fieldProblems[0] == [.labelEmpty] && c.fieldProblems[1] == [.labelTooLong])
    }

    @Test func atMost64Fields() {
        let fields = (1...65).map { DraftField(label: "F\($0)", kind: "text") }
        #expect(ItemChecks.check(ItemDraft(name: "P", fields: fields)).problems.contains(.tooManyFields))
    }

    @Test func tagsAreNormalisedAsTheVaultDoes() {
        #expect(ItemChecks.normalizeTag("  Travel   Plans ") == "travel plans")
        #expect(ItemChecks.normalizeTag("-dash") == nil && ItemChecks.normalizeTag("@other") == nil)
        #expect(ItemChecks.normalizeTag("@profile") == "@profile" && ItemChecks.normalizeTag("@profile", reserved: false) == nil)
        #expect(ItemChecks.normalizeTags(["B", "a", "A", " "]) == ["a", "b"])
        #expect(ItemChecks.check(draft(tags: ["Medical", "medical", "Travel"])).tags == ["medical", "travel"])
        #expect(ItemChecks.check(draft(tags: ["ok", "!no"])).problems.contains(.tagInvalid))
        #expect(ItemChecks.check(draft(tags: (1...17).map { "t\($0)" })).problems.contains(.tooManyTags))
    }

    @Test func theProfileTagStaysOnDataItems() {
        #expect(ItemChecks.check(draft(tags: ["@profile"])).ok)
        #expect(ItemChecks.check(draft(s: .secret, tags: ["@profile"])).problems.contains(.profileNotData))
    }

    @Test func theSizeIsTheContentEncodingWithoutWhatTheVaultAssigns() {
        // VAULT-MESSAGING 0.21.0 §10.7 Size: no item_id, version, times or field ids; template only when set, notes only
        // when not empty, tags and fields always.
        let d = draft(text("text", "X123"))
        let expected = #"{"name":"Passport","category":"identity_document","sensitivity":"data","tags":[],"fields":[{"label":"L","kind":"text","value":"X123"}]}"#
        #expect(ItemChecks.check(d).size == expected.utf8.count)
        var full = d
        full.template = "passport"
        full.tags = ["Travel", "id"]
        full.notes = "n"
        full.sensitivity = .secret
        let expectedFull = #"{"name":"Passport","category":"identity_document","sensitivity":"secret","template":"passport","tags":["id","travel"],"fields":[{"label":"L","kind":"text","value":"X123"}],"notes":"n"}"#
        #expect(ItemChecks.check(full).size == expectedFull.utf8.count && ItemChecks.check(full).exact)
    }

    @Test func theSizeCountsBytesAndExactlyTheVaultsEscapes() {
        // Raw UTF-8; only " \ LF tab U+2028 U+2029 are escaped (Go's encoding/json without HTML escaping).
        let d = ItemDraft(name: "é<&>", fields: [DraftField(label: "q\"", kind: "multiline", text: "a\nb\t\\ \u{2028}\u{2029}")])
        let expected = #"{"name":"é<&>","category":"other","sensitivity":"data","tags":[],"fields":[{"label":"q\"","kind":"multiline","value":"a\nb\t\\ \u2028\u2029"}]}"#
        #expect(ItemChecks.check(d).size == expected.utf8.count)
        // An address: its non-empty members in order; {} when all are empty.
        let a = ItemDraft(name: "A", fields: [DraftField(label: "Home", kind: "address")])
        #expect(ItemChecks.check(a).size == #"{"name":"A","category":"other","sensitivity":"data","tags":[],"fields":[{"label":"Home","kind":"address","value":{}}]}"#.utf8.count)
    }

    @Test func keptValuesCountFromTheStoredSize() {
        // A secret item from item.get (no values) with the vault's size: what the kept values add is size − metadata.
        let stored = ItemDetail(
            itemID: "01S", version: 2, name: "Login", category: "login", sensitivity: .secret,
            fields: [ItemFieldView(fieldID: "f1", label: "User", kind: "text"), ItemFieldView(fieldID: "f2", label: "Password", kind: "password")],
            hasNotes: true, revealed: false, size: 300
        )
        let d = ItemDraft.of(stored)
        let visible = ItemChecks.visibleSize(d, tags: [])
        #expect(d.base == KeptBase(fieldIDs: ["f1", "f2"], notes: true, bytes: 300 - visible))
        let c = ItemChecks.check(d)
        #expect(c.size == 300 && c.exact && c.roomLeft == ItemChecks.maxItemBytes - 300)
        // A renamed label still counts exactly: only the label's bytes change.
        var renamed = d
        renamed.fields[0].label = "User name"
        #expect(ItemChecks.check(renamed).size == 305 && ItemChecks.check(renamed).exact)
        // A kept value replaced (or a field removed, or the notes) leaves an upper bound.
        var typed = d
        typed.fields[1].text = "new"
        typed.fields[1].kept = false
        #expect(!ItemChecks.check(typed).exact && ItemChecks.check(typed).size == 303)
        var notesDropped = d
        notesDropped.keepNotes = false
        #expect(!ItemChecks.check(notesDropped).exact)
        // Without the vault's size (an older vault, or a critical item not written since): the size is not known.
        var noSize = stored
        noSize.size = nil
        let unknown = ItemDraft.of(noSize)
        #expect(unknown.base?.bytes == nil && !ItemChecks.check(unknown).sizeKnown && ItemChecks.check(unknown).roomLeft == nil)
    }

    @Test func anUpperBoundNeverRefusesWhatTheVaultMayAccept() {
        let stored = ItemDetail(
            itemID: "01C", version: 2, name: "Phrase", category: "crypto_wallet", sensitivity: .critical,
            fields: [ItemFieldView(fieldID: "f1", label: "Words", kind: "multiline"), ItemFieldView(fieldID: "f2", label: "Old", kind: "multiline")],
            revealed: false, size: 12_000
        )
        let d = ItemDraft.of(stored)
        // Removing a field drops some of the kept bytes, how many is not known: 12,000 + 500 is only an upper bound.
        let big = DraftField(label: "New", kind: "text", text: String(repeating: "x", count: 500))
        var edited = d
        edited.fields = [d.fields[0], big]
        let c = ItemChecks.check(edited)
        #expect(!c.exact && c.size > ItemChecks.maxCriticalBytes && !c.problems.contains(.tooLarge))
        // With every kept value still there, the size is exact and refuses.
        var grown = d
        grown.fields.append(big)
        #expect(ItemChecks.check(grown).problems.contains(.tooLarge))
    }

    @Test func aKeptValueIsNotCheckedButAFileFieldIsRefused() {
        #expect(ItemChecks.check(draft(DraftField(fieldID: "f1", label: "Date", kind: "date", kept: true))).ok)
        #expect(problems(draft(text("file", "x"))).contains(.valueInvalid))
        #expect(!FieldKinds.choosable.contains(FieldKinds.file))
    }

    @Test func aRevealedOrDataItemIsEditedWithItsValues() {
        let d = ItemDetail(
            itemID: "01A", version: 1, name: "Passport", category: "identity_document", sensitivity: .data,
            fields: [ItemFieldView(fieldID: "f1", label: "Number", kind: "text", value: .text("X1"))], notes: "n", hasNotes: true
        )
        let draft = ItemDraft.of(d)
        #expect(!draft.keeps && draft.base == nil && draft.notes == "n")
    }

    @Test func aCriticalItemIsBoundedBy12KiB() {
        let big = text("multiline", String(repeating: "x", count: 13_000))
        #expect(ItemChecks.check(draft(big, s: .critical)).problems.contains(.tooLarge))
        #expect(!ItemChecks.check(draft(big, s: .secret)).problems.contains(.tooLarge))
        #expect(ItemChecks.check(draft(s: .critical)).maxSize == ItemChecks.maxCriticalBytes)
    }

    @Test func anItemIsBoundedBy64KiB() {
        let fields = (1...5).map { _ in text("multiline", String(repeating: "y", count: 14_000)) }
        #expect(ItemChecks.check(ItemDraft(name: "P", fields: fields)).problems.contains(.tooLarge))
    }

    @Test func addressValuesEncodeTheirNonEmptyMembersInOrder() {
        #expect(ItemChecks.valueJSON(.address(AddressValue(street: "A 1", city: "Berlin", country: "DE"))) == #"{"street":"A 1","city":"Berlin","country":"DE"}"#)
    }

    @Test func filtersMatchNameTagCategoryAndSensitivity() {
        let a = ItemSummary(itemID: "1", version: 1, name: "Passport", category: "identity_document", sensitivity: .data, tags: ["travel"])
        let b = ItemSummary(itemID: "2", version: 1, name: "bank login", category: "login", sensitivity: .secret, tags: ["money"])
        let c = ItemSummary(itemID: "3", version: 1, name: "Alpha phrase", category: "crypto_wallet", sensitivity: .critical)
        let all = [a, b, c]
        #expect(ItemFilter().apply(all) == [c, b, a])
        #expect(ItemFilter(query: "PASS").apply(all) == [a] && ItemFilter(query: "mon").apply(all) == [b])
        #expect(ItemFilter(tag: "travel").apply(all) == [a] && ItemFilter(category: "login").apply(all) == [b])
        #expect(ItemFilter(sensitivity: .critical).apply(all) == [c])
        #expect(ItemFilter(tag: "money", sensitivity: .data).apply(all).isEmpty)
    }

    @Test func valuesAndDraftsAreNeverPrinted() {
        let f = DraftField(fieldID: "f1", label: "Password", kind: "password", text: "hunter2")
        let d = ItemDraft(name: "Login", fields: [f], notes: "secret notes")
        for s in [String(describing: f), String(reflecting: f), String(describing: d), String(reflecting: d), String(reflecting: FieldValue.text("hunter2"))] {
            #expect(!s.contains("hunter2") && !s.contains("secret notes"), "\(s)")
        }
        #expect(Sensitivity.of("newer") == .secret && Sensitivity.of(nil) == .data)
    }
}

// swiftlint:enable line_length
