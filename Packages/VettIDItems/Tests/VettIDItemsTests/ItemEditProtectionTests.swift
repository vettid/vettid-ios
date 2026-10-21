import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDItems

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The protection picked in the editor (§10.7, owner request 2026-10-08), the sharing notice (the dry run, or an older
/// vault's rules), and the dialogs of the fields and the categories. Mirrors vettid-android `ItemEditViewModelTest`.
@MainActor
@Suite struct ItemEditProtectionTests {
    let f = EditFixture()

    @Test func anEmptyNameSavesUnderTheTemplatesName() async throws {
        let vm = f.vm(template: "payment_card")
        #expect(vm.state.draft.name == "" && vm.state.nameHint == "Payment card" && vm.state.check.ok)
        vm.save()
        await vm.settle()
        #expect(try #require(f.stored(vm.state.savedID)).name == "Payment card")
        let typed = f.vm(template: "payment_card")
        typed.setName("Visa")
        typed.save()
        await typed.settle()
        #expect(try #require(f.stored(typed.state.savedID)).name == "Visa")
    }

    @Test func aBlankItemStillNeedsAName() async {
        let vm = f.vm()
        #expect(vm.state.nameHint == nil)
        vm.save()
        await vm.settle()
        #expect(vm.state.check.problems.contains(.nameEmpty) && !f.items.calls.contains("create"))
    }

    @Test func noTemplatePreTypesAnything() {
        for t in ItemTemplates.all {
            let s = f.vm(template: t.id).state
            #expect(s.draft.name == "" && s.draft.notes == "" && s.tagInput == "", "\(t.id)")
            #expect(s.draft.fields.allSatisfy { $0.text.isEmpty && $0.address == AddressValue() && !$0.kept }, "\(t.id)")
        }
    }

    @Test func standardToSecretNeedsNothingMore() async throws {
        let vm = await f.editing("01A", .data)
        vm.setSensitivity(.secret)
        #expect(vm.state.protection == .secret && vm.state.draft.sensitivity == .data && vm.state.dirty)
        #expect(vm.state.protectionNote != nil)
        vm.save()
        await vm.settle()
        #expect(vm.state.prompt == nil && vm.state.savedID == "01A")
        // Only the protection changed: no content is sent.
        #expect(f.writes == ["get", "setSensitivity"])
        #expect(try #require(f.stored("01A")).sensitivity == .secret)
    }

    @Test func theContentIsSavedBeforeTheProtection() async throws {
        let vm = await f.editing("01A", .secret)
        vm.setName("Renamed")
        vm.setSensitivity(.data)
        vm.save()
        await vm.settle()
        #expect(f.writes == ["get", "update", "setSensitivity"])
        let stored = try #require(f.stored("01A"))
        #expect(stored.name == "Renamed" && stored.sensitivity == .data)
    }

    @Test func movingToCriticalAsksForThePasswordOnce() async throws {
        let vm = await f.editing("01A", .data)
        vm.setName("Seed")
        vm.setSensitivity(.critical)
        vm.save()
        #expect(vm.state.prompt?.purpose == .save && !f.items.calls.contains("update"))
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        #expect(vm.state.savedID == "01A" && f.writes == ["get", "update", "setSensitivity"])
        let stored = try #require(f.stored("01A"))
        #expect(stored.sensitivity == .critical && stored.name == "Seed")
    }

    @Test func leavingCriticalWarnsFirst() async throws {
        let vm = await f.editing("01C", .critical)
        vm.setSensitivity(.secret)
        vm.save()
        #expect(vm.state.confirmLeaveCritical && vm.state.prompt == nil)
        vm.dismissLeaveCritical()
        #expect(!vm.state.confirmLeaveCritical)
        vm.save()
        vm.confirmLeaveCritical()
        #expect(vm.state.prompt?.purpose == .save)
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        #expect(try #require(f.stored("01C")).sensitivity == .secret)
        // Nothing typed: only the protection operation.
        #expect(!f.items.calls.contains("updateCritical"))
    }

    @Test func aRefusedProtectionChangeKeepsTheSavedContentAndRetriesOnlyIt() async throws {
        let vm = await f.editing("01A", .data)
        vm.setName("Renamed")
        vm.addField("Code", kind: FieldKinds.text)
        vm.setFieldText(1, "1234")
        vm.setSensitivity(.critical)
        let limit = VaultLimit("critical_items", max: 1_000)
        f.items.fail["setSensitivity"] = VaultFailure(.limit, code: "limit", limit: limit)
        vm.save()
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        // The content is stored; the editor shows it as stored, with the new protection still picked.
        var stored = try #require(f.stored("01A"))
        #expect(stored.name == "Renamed" && stored.sensitivity == .data)
        #expect(vm.state.savedID == nil && vm.state.error == .limit && vm.state.limit == limit && vm.state.savedButProtection)
        #expect(vm.state.protectionTo == .critical && vm.state.draft.fields.allSatisfy { $0.fieldID != nil })
        // Saving again only retries the protection (no duplicate fields).
        let updates = f.items.calls.count { $0 == "update" }
        vm.save()
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        stored = try #require(f.stored("01A"))
        #expect(vm.state.savedID == "01A" && f.items.calls.count { $0 == "update" } == updates)
        #expect(stored.fields.count == 2 && stored.sensitivity == .critical)
    }

    @Test func aWrongPasswordForACriticalContentSaveSavesNothing() async throws {
        let vm = await f.editing("01C", .critical)
        vm.setName("Renamed")
        vm.setSensitivity(.secret)
        vm.save()
        vm.confirmLeaveCritical()
        vm.setPassword("wrong")
        vm.submitPassword()
        await vm.settle()
        #expect(vm.state.prompt?.error == .badPassword && !vm.state.savedButProtection)
        #expect(try #require(f.stored("01C")).sensitivity == .critical && !f.items.calls.contains("setSensitivity"))
        vm.setPassword("correct horse")
        vm.submitPassword()
        await vm.settle()
        let stored = try #require(f.stored("01C"))
        #expect(stored.name == "Renamed" && stored.sensitivity == .secret)
    }

    @Test func aSharedProfileItemStaysStandard() async {
        let vm = await f.editing("01P", .data, tags: ["@profile"])
        vm.setSensitivity(.secret)
        #expect(vm.state.protectionTo == nil && vm.state.protectionNote == ItemsStrings.protectionProfile)
        vm.setInProfile(false)
        vm.setSensitivity(.secret)
        #expect(vm.state.protectionTo == .secret)
        vm.setSensitivity(.data) // back to what it is: no change
        #expect(vm.state.protectionTo == nil)
    }

    @Test func aCriticalTargetChecksTheCriticalSizeLimit() async {
        f.items.add(FakeItems.item("01B", "Big", fields: [("Text", String(repeating: "x", count: 13_000))]))
        let vm = f.vm(itemID: "01B")
        await vm.settle()
        #expect(vm.state.check.ok)
        vm.setSensitivity(.critical)
        #expect(vm.state.check.problems.contains(.tooLarge))
        vm.save()
        #expect(vm.state.prompt == nil)
    }

    // MARK: - The sharing notice

    private func connection(_ id: String, _ first: String, _ last: String) -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: "", state: .active)
        c.firstName = first
        c.lastName = last
        return c
    }

    @Test func theSharingNoticeIsTheVaultsDryRun() async {
        f.connections.connections = [connection("c1", "Dana", "Lee"), connection("c2", "Jo", "Park")]
        f.items.effect = ShareEffect(
            shares: [EffectShare(ruleID: "r1", subject: ShareSubject(connectionID: "c1"), mode: .auto), EffectShare(ruleID: "r9", subject: ShareSubject(agentID: "a1"), mode: .ask)],
            withdrawals: [EffectWithdrawal(ruleID: "r2", subject: ShareSubject(connectionID: "c2"), state: "included")]
        )
        // The local rules would say otherwise: they are not read while the vault answers the dry run.
        f.sharing.rulesStored.append(ShareRule(ruleID: "r3", connectionID: "c2", tags: ["medical"]))
        let vm = f.vm(template: "allergies")
        let expected = [ShareImpact(connectionName: "Dana Lee", mode: .auto), ShareImpact(connectionName: "Jo Park", mode: .ask, withdrawn: true)]
        #expect(await eventually { vm.state.shareImpact == expected })
        #expect(f.items.effectAsked == [["medical"]] && !f.sharing.calls.contains("rules"))
        // A change of tags asks again; the same tags do not.
        vm.setTagInput("travel")
        vm.addTag()
        vm.setName("Allergy list")
        #expect(await eventually { f.items.effectAsked.count == 2 })
        #expect(f.items.effectAsked == [["medical"], ["medical", "travel"]])
    }

    @Test func anAskRuleThatHoldsAShareIsNamed() async throws {
        f.connections.connections = [connection("c1", "Dana", "Lee")]
        let hold = ShareRule(ruleID: "r9", connectionID: "c1", tags: ["medical"])
        f.sharing.rulesStored.append(hold)
        f.items.effect = ShareEffect(shares: [EffectShare(ruleID: "r1", subject: ShareSubject(connectionID: "c1"), mode: .auto, askRuleID: "r9")])
        let vm = f.vm(template: "allergies")
        #expect(await eventually { vm.state.shareImpact.first?.askRule == hold })
    }

    @Test func anExistingItemsUnchangedTagsAskNothing() async {
        let vm = await f.editing("01P", .data, tags: ["travel"])
        #expect(f.items.effectAsked.isEmpty)
        vm.setTagInput("id")
        vm.addTag()
        #expect(await eventually { f.items.effectAsked == [["id", "travel"]] })
    }

    @Test func anOlderVaultsRulesShowWhatSavingWouldShare() async {
        // Before 0.21.0 the vault refuses the dry run (bad_request): the app matches the rules itself.
        f.items.fail["shareEffect"] = VaultFailure(.other, code: "bad_request")
        f.connections.connections = [connection("c1", "Dana", "Lee")]
        f.sharing.rulesStored.append(ShareRule(ruleID: "r1", connectionID: "c1", tags: ["medical"]))
        f.sharing.rulesStored.append(ShareRule(ruleID: "r2", connectionID: "c1", tags: ["medical", "travel"], match: .all, mode: .auto))
        let vm = f.vm(template: "allergies")
        #expect(await eventually { vm.state.shareImpact.map(\.connectionName) == ["Dana Lee"] })
        #expect(vm.state.shareImpact.first?.mode == .ask)
        vm.setTagInput("travel")
        vm.addTag()
        #expect(await eventually { vm.state.shareImpact.count == 2 })
        vm.removeTag("medical")
        #expect(await eventually { vm.state.shareImpact.isEmpty })
        // The fallback stays: no second dry run.
        #expect(f.items.calls.count { $0 == "shareEffect" } == 1)
    }

    // MARK: - Dialogs

    @Test func addingAFieldAsksForItsLabelAndTypeFirst() {
        // Value-first fields (owner feedback 2026-10-08): the label is asked for once, then the value is typed.
        let vm = f.vm()
        vm.askAddField()
        #expect(vm.state.dialog == .addField())
        vm.confirmDialog() // no label: it stays open, nothing is added
        #expect(vm.state.draft.fields.isEmpty)
        vm.setDialogText(String(repeating: "é", count: 33)) // 66 bytes: over §10.7's 64
        vm.confirmDialog()
        #expect(vm.state.draft.fields.isEmpty)
        vm.setDialogText("  Cardholder ")
        vm.setDialogKind(FieldKinds.file) // never offered
        #expect(vm.state.dialog == .addField(label: "  Cardholder ", kind: FieldKinds.text))
        vm.setDialogKind(FieldKinds.date)
        vm.confirmDialog()
        #expect(vm.state.dialog == nil && vm.state.draft.fields.map(\.label) == ["Cardholder"])
        #expect(vm.state.draft.fields.map(\.kind) == [FieldKinds.date] && vm.state.focusField == 0)
        vm.fieldFocused()
        #expect(vm.state.focusField == nil)
        // A dismissed dialog adds nothing.
        vm.askAddField()
        vm.setDialogText("PIN")
        vm.dismissDialog()
        #expect(vm.state.dialog == nil && vm.state.draft.fields.count == 1)
    }

    @Test func aFieldIsRenamedThroughItsDialog() {
        let vm = f.vm(template: "passport")
        vm.askRenameField(1)
        #expect(vm.state.dialog == .renameField(index: 1, label: "Full name"))
        vm.setDialogText("")
        vm.confirmDialog()
        #expect(vm.state.draft.fields[1].label == "Full name")
        vm.setDialogText("Name on passport ")
        vm.confirmDialog()
        #expect(vm.state.dialog == nil && vm.state.draft.fields[1].label == "Name on passport" && vm.state.dirty)
    }

    @Test func onlyAnUnsavedFieldChangesItsType() async {
        f.items.add(FakeItems.item("01S", "Login", sensitivity: .secret, fields: [("Password", "hunter2")]))
        let vm = f.vm(itemID: "01S")
        await vm.settle()
        vm.askFieldKind(0) // saved (§10.7): its kind stays
        #expect(vm.state.dialog == nil)
        vm.askAddField()
        vm.setDialogText("Site")
        vm.confirmDialog()
        vm.askFieldKind(1)
        #expect(vm.state.dialog == .fieldKind(index: 1, kind: FieldKinds.text))
        vm.setDialogKind(FieldKinds.url)
        vm.confirmDialog()
        #expect(vm.state.draft.fields[1].kind == FieldKinds.url && vm.state.draft.fields[0].kept)
    }

    @Test func aNewCategoryIsDerivedFromItsName() {
        let vm = f.vm()
        vm.askNewCategory()
        vm.setDialogText("2fa codes")
        vm.confirmDialog() // no identifier: it stays open
        #expect(vm.state.dialog == .newCategory(name: "2fa codes"))
        vm.setDialogText("Loyalty cards")
        vm.confirmDialog()
        #expect(vm.state.dialog == nil && vm.state.draft.category == "loyalty_cards" && vm.state.pickerCustoms == ["loyalty_cards"])
        #expect(!vm.state.check.problems.contains(.categoryInvalid))
        // A name that is a recommended category selects it.
        vm.askNewCategory()
        vm.setDialogText("Payment card")
        vm.confirmDialog()
        #expect(vm.state.draft.category == "payment_card" && vm.state.pickerCustoms.isEmpty)
    }

    @Test func thePickerOffersTheMembersOwnCategories() async {
        f.items.add(FakeItems.item("01G", "Gym card", category: "gym"))
        f.items.add(FakeItems.item("01L", "Coffee card", category: "loyalty_cards"))
        f.items.add(FakeItems.item("01M", "Bonus card", category: "loyalty_cards"))
        f.items.add(FakeItems.item("01P", "Passport", category: "identity_document"))
        let vm = f.vm()
        #expect(await eventually { vm.state.customCategories == ["gym", "loyalty_cards"] })
        f.items.add(FakeItems.item("01T", "Ticket", category: "tickets"))
        #expect(await eventually { vm.state.pickerCustoms == ["gym", "loyalty_cards", "tickets"] })
    }
}

// swiftlint:enable line_length
