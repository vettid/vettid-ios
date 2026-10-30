import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDItems

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The edit screen against ``FakeItems`` and ``FakeSharing``, shared by the edit suites.
@MainActor
struct EditFixture {
    let items = FakeItems()
    let sharing = FakeSharing()
    let connections = FakeConnections()

    func vm(itemID: String? = nil, template: String? = nil) -> ItemEditViewModel {
        ItemEditViewModel(itemID: itemID, template: template, items: items, sharing: sharing, connections: connections, impactDelay: .zero)
    }

    /// An existing item's screen, loaded.
    func editing(_ id: String, _ sensitivity: Sensitivity, tags: [String] = []) async -> ItemEditViewModel {
        items.add(FakeItems.item(id, "Item", sensitivity: sensitivity, tags: tags))
        let vm = vm(itemID: id)
        await vm.settle()
        return vm
    }

    func stored(_ id: String?) -> ItemDetail? { items.stored.first { $0.itemID == id } }

    /// The calls that write or read one item (not the list, not the dry run).
    var writes: [String] { items.calls.filter { $0 != "refresh" && $0 != "shareEffect" } }
}

/// Adding from templates and editing (§10.7): checks before sending, kept values, fields and their dialogs. Mirrors
/// vettid-android `ItemEditViewModelTest`.
@MainActor
@Suite struct ItemEditViewModelTests {
    let f = EditFixture()

    @Test func aTemplatePrefillsTheDraft() {
        let s = f.vm(template: "passport").state
        // Owner request 2026-10-08: the template's name is the placeholder, never pre-typed.
        #expect(s.draft.name == "" && s.nameHint == "Passport")
        #expect(s.draft.category == "identity_document" && s.draft.template == "passport")
        #expect(s.draft.tags == ["identity", "travel"] && s.draft.fields.count == 7)
        #expect(s.draft.fields[3].kind == FieldKinds.date && s.isNew && !s.dirty)
    }

    @Test func templatesSuggestTheirSensitivity() {
        #expect(f.vm(template: "login").state.draft.sensitivity == .secret)
        #expect(f.vm(template: "recovery_phrase").state.draft.sensitivity == .critical)
        #expect(f.vm().state.draft.sensitivity == .data)
    }

    @Test func everyRegistryTemplatePassesTheChecksOnceNamed() {
        for t in ItemTemplates.all {
            var d = t.draft()
            d.name = t.name
            #expect(ItemChecks.check(d).ok, "\(t.id)")
        }
    }

    @Test func problemsShowOnlyAfterTheFirstSaveAndNothingIsSent() async throws {
        // A blank item (no template) still needs a name.
        let vm = f.vm()
        vm.addField("Expires", kind: FieldKinds.date)
        #expect(!vm.state.showErrors)
        vm.setFieldText(0, "1st of May")
        vm.save()
        await vm.settle()
        #expect(vm.state.showErrors && vm.state.check.problems.contains(.nameEmpty))
        #expect(try #require(vm.state.check.fieldProblems[0]).contains(.valueInvalid))
        #expect(!f.items.calls.contains("create"))
    }

    /// Each refused save is counted, so that the screen takes the member to the first problem every time, and names how
    /// many there are (I4 audit, accessibility).
    @Test func aRefusedSavePointsToTheFirstProblem() async {
        let vm = f.vm()
        vm.addField("Expires", kind: FieldKinds.date)
        vm.setFieldText(0, "1st of May")
        #expect(vm.state.firstProblem == nil && vm.state.refusedSaves == 0)
        vm.save()
        await vm.settle()
        #expect(vm.state.refusedSaves == 1 && vm.state.firstProblem == .name && vm.state.problemCount == 2)
        vm.setName("Card")
        vm.save()
        await vm.settle()
        #expect(vm.state.refusedSaves == 2 && vm.state.firstProblem == .field(0) && vm.state.problemCount == 1)
    }

    /// The order is the form's: the name, the fields by index, the notes, then the list of the others.
    @Test func theFirstProblemFollowsTheForm() {
        var s = ItemEditState()
        s.showErrors = true
        s.check = DraftCheck(problems: [.notesTooLong, .tooManyTags], fieldProblems: [3: [.labelEmpty], 1: [.valueInvalid, .labelEmpty]])
        #expect(s.firstProblem == .field(1) && s.problemCount == 5)
        s.check.fieldProblems = [:]
        #expect(s.firstProblem == .notes && s.problemCount == 2)
        s.check.problems = [.tooLarge]
        #expect(s.firstProblem == .summary && s.problemCount == 1)
        s.showErrors = false
        #expect(s.firstProblem == nil)
    }

    @Test func aStandardItemIsCreated() async throws {
        let vm = f.vm(template: "postal_address")
        vm.setFieldAddress(0, AddressValue(city: "London", country: "GB"))
        vm.setTagInput(" Family ")
        vm.addTag()
        vm.save()
        await vm.settle()
        let saved = try #require(f.stored(vm.state.savedID))
        #expect(saved.tags == ["family"] && saved.template == "postal_address")
        // The tag gets its colour stored if it has none (owner decision 2026-10-09).
        #expect(f.sharing.used == [["family"]])
        #expect(saved.fields.map(\.value) == [.address(AddressValue(city: "London", country: "GB"))])
        #expect(!vm.state.inProfile)
    }

    @Test func aPhoneIsStoredInE164() async throws {
        // VAULT-MESSAGING §10.7 "Phone values" (0.55.0): the extension dropped, a possible number in E.164.
        let vm = ItemEditViewModel(itemID: nil, template: "phone_number", items: f.items, sharing: f.sharing, connections: f.connections, impactDelay: .zero, region: "GB")
        vm.setFieldText(0, "020 7946 0958 x12")
        vm.save()
        await vm.settle()
        #expect(try #require(f.stored(vm.state.savedID)).fields.map(\.value) == [.text("+442079460958")])
    }

    @Test func noTemplateSuggestsAReservedTag() {
        // VAULT-ITEMS 0.1.1 (owner decision 2026-10-08): the shared profile holds only what the member tags.
        for t in ItemTemplates.all {
            #expect(!t.tags.contains { $0.hasPrefix("@") }, "\(t.id)")
            #expect(!f.vm(template: t.id).state.inProfile, "\(t.id)")
        }
    }

    @Test func contactInformationIsOneItemPerContactPoint() {
        #expect(ItemTemplates.template("contact_card") == nil)
        let kinds = ["email_address": FieldKinds.email, "phone_number": FieldKinds.phone, "postal_address": FieldKinds.address, "website": FieldKinds.url]
        for (id, kind) in kinds {
            let d = f.vm(template: id).state.draft
            #expect(d.template == id && d.category == "contact" && d.sensitivity == .data && d.tags.isEmpty)
            #expect(d.fields.map(\.kind) == [kind])
        }
    }

    @Test func anOldContactCardStillEdits() async throws {
        var old = FakeItems.item("01K", "Contact details", tags: ["@profile"], category: "contact", fields: [("Email", "sam@example.org")])
        old.template = "contact_card"
        f.items.add(old)
        let vm = f.vm(itemID: "01K")
        await vm.settle()
        #expect(vm.state.inProfile)
        vm.setFieldText(0, "sam@example.com")
        vm.save()
        await vm.settle()
        let stored = try #require(f.stored("01K"))
        #expect(stored.template == "contact_card" && stored.tags == ["@profile"] && stored.fields.map(\.value) == [.text("sam@example.com")])
    }

    @Test func theSharedProfileIsAChoiceForStandardItemsOnly() {
        let vm = f.vm(template: "email_address")
        vm.setInProfile(true)
        #expect(vm.state.inProfile)
        vm.setSensitivity(.secret)
        vm.save()
        #expect(vm.state.check.problems.contains(.profileNotData))
        vm.setInProfile(false)
        #expect(!vm.state.inProfile && vm.state.check.ok)
        vm.setInProfile(true) // a secret item cannot carry it
        #expect(!vm.state.inProfile)
        vm.setSensitivity(.data)
        vm.setInProfile(true)
        #expect(vm.state.draft.tags == ["@profile"])
    }

    @Test func aBlankItemStartsWithoutFields() {
        let d = f.vm().state.draft
        #expect(d.fields.isEmpty && d.template == nil)
    }

    @Test func aCriticalItemIsSavedWithThePassword() async throws {
        let vm = f.vm(template: "recovery_phrase")
        vm.setFieldText(1, "abandon ability able")
        vm.save()
        #expect(vm.state.prompt?.purpose == .save && f.items.calls.isEmpty)
        vm.setPassword("wrong")
        vm.submitPassword()
        await vm.settle()
        #expect(vm.state.prompt?.error == .badPassword && vm.state.prompt?.password == "")
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        #expect(try #require(f.stored(vm.state.savedID)).sensitivity == .critical)
        #expect(vm.state.prompt == nil)
    }

    @Test func editingACriticalItemKeepsItsValuesAndTakesOnePassword() async throws {
        // VAULT-MESSAGING 0.21.0 §10.7 Kept values: nothing is opened to edit; the save is one credential operation.
        var phrase = FakeItems.item("01C", "Phrase", sensitivity: .critical, fields: [("Words", "a b"), ("Passphrase", "p")])
        phrase.notes = "cold"
        phrase.hasNotes = true
        f.items.add(phrase)
        let vm = f.vm(itemID: "01C")
        await vm.settle()
        #expect(vm.state.prompt == nil)
        #expect(vm.state.draft.fields.allSatisfy { $0.kept && $0.text.isEmpty } && vm.state.draft.keepNotes)
        vm.setFieldLabel(0, "Recovery words")
        vm.setFieldText(1, "new passphrase")
        vm.save()
        #expect(vm.state.prompt?.purpose == .save)
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        #expect(vm.state.savedID == "01C" && f.writes == ["get", "updateCritical"])
        let sent = try #require(f.items.lastDraft)
        #expect(sent.fields[0].kept && !sent.fields[1].kept)
        let stored = try #require(f.stored("01C"))
        #expect(stored.fields.map(\.value) == [.text("a b"), .text("new passphrase")] && stored.fields[0].label == "Recovery words")
        #expect(stored.notes == "cold")
    }

    @Test func editingASecretItemRevealsNothing() async throws {
        f.items.add(FakeItems.item("01S", "Login", sensitivity: .secret, fields: [("Password", "hunter2")]))
        let vm = f.vm(itemID: "01S")
        await vm.settle()
        #expect(!f.items.calls.contains("reveal"))
        #expect(vm.state.draft.fields.map(\.kept) == [true] && vm.state.draft.fields.map(\.text) == [""])
        vm.setFieldText(0, "hunter3")
        #expect(vm.state.draft.fields.map(\.kept) == [false])
        vm.save()
        await vm.settle()
        #expect(!f.items.calls.contains("reveal"))
        #expect(try #require(f.stored("01S")).fields.map(\.value) == [.text("hunter3")])
    }

    @Test func keptNotesAreReplacedByTypingOrRemoved() async throws {
        var login = FakeItems.item("01S", "Login", sensitivity: .secret)
        login.notes = "branch"
        login.hasNotes = true
        f.items.add(login)
        let vm = f.vm(itemID: "01S")
        await vm.settle()
        #expect(vm.state.draft.keepNotes)
        vm.removeNotes()
        #expect(!vm.state.draft.keepNotes)
        vm.save()
        await vm.settle()
        #expect(try #require(f.stored("01S")).notes == nil)
    }

    @Test func theRoomLeftComesFromTheStoredSize() async throws {
        f.items.add(FakeItems.item("01S", "Login", sensitivity: .secret, fields: [("Password", String(repeating: "x", count: 5_000))]))
        let expected = ItemChecks.check(ItemDraft.of(try #require(f.stored("01S")))).size
        let vm = f.vm(itemID: "01S")
        await vm.settle()
        #expect(vm.state.check.size == expected && vm.state.check.exact && vm.state.check.roomLeft == ItemChecks.maxItemBytes - expected)
        // An older vault gives no size: nothing is claimed about the room left.
        f.items.reportSize = false
        let older = f.vm(itemID: "01S")
        await older.settle()
        #expect(older.state.check.roomLeft == nil)
    }

    @Test func aNamedLimitIsKept() async {
        f.items.add(FakeItems.item("01P", "Passport"))
        let vm = f.vm(itemID: "01P")
        await vm.settle()
        let limit = VaultLimit("share_pending", max: 4_096)
        f.items.fail["update"] = VaultFailure(.limit, code: "limit", limit: limit)
        vm.setTagInput("medical")
        vm.addTag()
        vm.save()
        await vm.settle()
        #expect(vm.state.error == .limit && vm.state.limit == limit)
        vm.dismissError()
        #expect(vm.state.limit == nil)
    }

    @Test func aFileFieldIsNeverOffered() {
        let vm = f.vm()
        vm.addField("Scan", kind: FieldKinds.file)
        #expect(vm.state.draft.fields.isEmpty)
    }

    @Test func aConflictIsShown() async {
        f.items.add(FakeItems.item("01P", "Passport"))
        let vm = f.vm(itemID: "01P")
        await vm.settle()
        f.items.fail["update"] = VaultFailure(.conflict, code: "conflict")
        vm.setName("Passport (old)")
        vm.save()
        await vm.settle()
        #expect(vm.state.error == .conflict && vm.state.savedID == nil)
    }

    @Test func fieldsAreAddedMovedAndRemoved() {
        let vm = f.vm()
        vm.addField("Text", kind: FieldKinds.text)
        vm.addField("PIN", kind: FieldKinds.password)
        vm.addField("Site", kind: FieldKinds.url)
        vm.moveField(2, by: -1)
        #expect(vm.state.draft.fields.map(\.label) == ["Text", "Site", "PIN"])
        vm.moveField(0, by: -1) // out of range: nothing moves
        vm.removeField(0)
        #expect(vm.state.draft.fields.map(\.label) == ["Site", "PIN"])
        vm.setFieldKind(0, FieldKinds.email)
        #expect(vm.state.draft.fields[0].kind == FieldKinds.email && vm.state.dirty)
    }

    @Test func anInvalidTagStaysInTheField() {
        let vm = f.vm()
        vm.setTagInput("-nope")
        vm.addTag()
        #expect(vm.state.tagInput == "-nope" && vm.state.draft.tags.isEmpty)
    }

    @Test func aCardsExpiryIsAMonthAndYear() async throws {
        // §10.7 allows `YYYY-MM`: a card's expiry is entered and stored so.
        let vm = f.vm(template: "payment_card")
        let i = try #require(vm.state.draft.fields.firstIndex { $0.label == "Expires" })
        #expect(vm.state.draft.fields[i].monthYear)
        #expect(!f.vm(template: "passport").state.draft.fields.contains { $0.monthYear })
        vm.setFieldText(i, "2031-04")
        vm.save()
        await vm.settle()
        let id = try #require(vm.state.savedID)
        #expect(try #require(f.stored(id)).fields[i].value == .text("2031-04"))
        // Edited again (its values kept: a secret item), it is still a month and year.
        let again = f.vm(itemID: id)
        await again.settle()
        #expect(again.state.draft.fields[i].kept && again.state.draft.fields[i].monthYear)
    }

    /// VAULT-ITEMS 0.1.2 (VAULT-MESSAGING 0.23.0 §10.7): the month picker follows the template field's `"format": "month"`;
    /// a stored value's form decides when editing.
    @Test func theMonthPickerFollowsTheTemplatesFormatHint() {
        let months = ItemTemplates.all.flatMap { t in t.fields.filter { $0.format == TemplateField.formatMonth }.map { (t.id, $0) } }
        #expect(months.map(\.0) == ["payment_card"] && months.allSatisfy(\.1.monthYear))
        #expect(!TemplateField(label: "Expires", kind: "text", format: TemplateField.formatMonth).monthYear)
        #expect(!TemplateField(label: "Expires", kind: "date", format: nil).monthYear)
        let labels: Set = ["Expires"]
        #expect(ItemTemplates.monthHint("date", "", "Expires", labels))
        #expect(!ItemTemplates.monthHint("date", "2031-04-30", "Expires", labels))
        #expect(!ItemTemplates.monthHint("date", "", "Issued", labels))
        #expect(!ItemTemplates.monthHint("text", "", "Expires", labels))
        let day = DraftField.of(ItemFieldView(fieldID: "f1", label: "Expires", kind: "date", value: .text("2031-04-30")))
        let month = DraftField.of(ItemFieldView(fieldID: "f1", label: "Expires", kind: "date", value: .text("2031-04")))
        #expect(!day.monthYear && month.monthYear && month.text == "2031-04")
    }

    /// A lock, the hold or a wipe: what was typed and a typed password are dropped, and the screen leaves.
    @Test func theDraftIsDroppedAndTheScreenClosesWhenTheItemsAreCleared() async {
        let vm = f.vm(template: "recovery_phrase")
        vm.setFieldText(1, "abandon ability able")
        vm.save()
        vm.setPassword("correct horse")
        f.items.clear()
        #expect(await eventually { vm.closed })
        #expect(vm.state.prompt == nil && !vm.state.draft.fields.contains { !$0.text.isEmpty })
    }
}

// swiftlint:enable line_length
