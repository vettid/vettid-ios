#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
@testable import VettIDItems
@testable import VettIDItemsUI
import VettIDUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Vault's screens: every state of the list, an item hidden, revealed and opened (with a one-time code), the
/// password step, the add/edit form with each kind of field and each dialog, and the template picker, rendered. Mirrors
/// vettid-android's `ItemsScreenTest` and `ItemInputScreenTest`.
@MainActor
@Suite struct ItemScreensTests {
    let chrome = ShellChrome(accountName: "Sam Lee", onMenu: {}, onAvatar: {})
    let summaries = [
        ItemSummary(itemID: "01P", version: 1, name: "Passport", category: "identity_document", sensitivity: .data, tags: ["travel", "@profile"], labels: [], updatedAt: Date()),
        ItemSummary(itemID: "01L", version: 1, name: "Bank login", category: "login", sensitivity: .secret, tags: [], labels: [], updatedAt: nil),
    ]

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.dark)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    @Test func everyStateOfTheListRenders() {
        var failed = ItemsState(load: .loaded)
        failed.error = .network
        var filtered = ItemsState(items: summaries, load: .loaded)
        filtered.filter.query = "nothing"
        for s in [ItemsState(), ItemsState(load: .loaded), failed, ItemsState(items: summaries, load: .loaded), filtered] {
            #expect(height(ItemsScreen(state: s, chrome: chrome, actions: ItemsActions())) > 0)
        }
        #expect(height(TemplatePickerScreen(onBack: {}, onPick: { _ in })) > 0)
    }

    private func item(_ s: Sensitivity, revealed: Bool) -> ItemDetail {
        let fields = [
            ItemFieldView(fieldID: "f1", label: "Website", kind: FieldKinds.url, value: revealed ? .text("https://bank.example") : nil),
            ItemFieldView(fieldID: "f2", label: "Password", kind: FieldKinds.password, value: revealed ? .text("hunter2") : nil),
            ItemFieldView(fieldID: "f3", label: "One-time code", kind: FieldKinds.otp, value: revealed ? .text("JBSWY3DPEHPK3PXP") : nil),
            ItemFieldView(fieldID: "f4", label: "Address", kind: FieldKinds.address, value: revealed ? .address(AddressValue(city: "London", country: "GB")) : nil),
        ]
        return ItemDetail(itemID: "01L", version: 2, name: "Bank login", category: "login", sensitivity: s, tags: ["money"], fields: fields, notes: revealed ? "branch" : nil, hasNotes: true, createdAt: Date(), updatedAt: Date(), revealed: revealed)
    }

    @Test func anItemRendersHiddenRevealedAndAtEachStep() {
        var states: [ItemDetailState] = [ItemDetailState(itemID: "01L")]
        for s in Sensitivity.allCases {
            states.append(ItemDetailState(itemID: "01L", item: item(s, revealed: false)))
            var shown = ItemDetailState(itemID: "01L", item: item(s, revealed: true))
            shown.shown = ["f2", "f3"]
            states.append(shown)
        }
        var missing = ItemDetailState(itemID: "01X")
        missing.loading = false
        missing.missing = true
        var failed = ItemDetailState(itemID: "01X")
        failed.loading = false
        failed.error = .network
        var prompt = ItemDetailState(itemID: "01L", item: item(.critical, revealed: false))
        prompt.prompt = PasswordPrompt(.open)
        var dialog = ItemDetailState(itemID: "01L", item: item(.critical, revealed: false))
        dialog.dialog = .protectionPick
        for s in states + [missing, failed, prompt, dialog] {
            #expect(height(ItemDetailScreen(state: s, actions: ItemDetailActions())) > 0)
        }
    }

    @Test func theOneTimeCodeIsInGroupsOfThree() {
        #expect(OtpCode.grouped("123456") == "123 456" && OtpCode.grouped("12345678") == "123 456 78")
    }

    @Test func thePasswordStepRendersWithAWrongPasswordAndABackoff() {
        var wrong = PasswordPrompt(.save)
        wrong.error = .badPassword
        var waiting = PasswordPrompt(.delete)
        waiting.retryUntil = Date().addingTimeInterval(30)
        for p in [PasswordPrompt(.open), wrong, waiting, PasswordPrompt(.protection)] {
            #expect(height(CredentialPasswordScreen(prompt: p, itemName: "Seed", onPassword: { _ in }, onSubmit: {}, onCancel: {})) > 0)
        }
    }

    @Test func theFormRendersEveryKindAndEveryDialog() {
        var s = ItemEditState()
        s.nameHint = "Login"
        s.draft = ItemDraft(category: "login", sensitivity: .secret, tags: ["money", "@profile"], fields: FieldKinds.choosable.map { DraftField(label: $0, kind: $0) } + [DraftField(fieldID: "f9", label: "Kept", kind: FieldKinds.text, kept: true), DraftField(label: "Expires", kind: FieldKinds.date, monthYear: true)], keepNotes: true)
        s.showErrors = true
        s.check = DraftCheck(problems: [.nameEmpty, .tooManyTags], fieldProblems: [0: [.valueInvalid]], size: 60_000)
        s.shareImpact = [ShareImpact(connectionName: "Dana Lee", mode: .auto), ShareImpact(connectionName: "", mode: .ask, withdrawn: true)]
        s.error = .limit
        s.savedButProtection = true
        var forms = [ItemEditState(), s]
        for d: EditDialog in [.addField(), .renameField(index: 0, label: "Text"), .fieldKind(index: 0, kind: FieldKinds.url), .newCategory(name: "2fa"), .newCategory(name: "Loyalty cards")] {
            var x = s
            x.dialog = d
            forms.append(x)
        }
        var data = s
        data.draft.sensitivity = .data
        var loading = ItemEditState(itemID: "01L")
        loading.loading = true
        var prompt = s
        prompt.prompt = PasswordPrompt(.save)
        for f in forms + [data, loading, prompt] {
            #expect(height(ItemEditScreen(state: f, actions: ItemEditActions())) > 0)
        }
        #expect(height(DialogSheet(title: "t", confirm: "c", enabled: true, onCancel: {}, onConfirm: {}) { FieldDialog(title: "Add", confirm: "Add", label: "", kind: FieldKinds.text, actions: ItemEditActions()) }) > 0)
        #expect(height(NewCategoryDialog(name: "1st", actions: ItemEditActions())) > 0)
        #expect(height(MonthPicker(stored: "2031-04") { _ in }) > 0 && height(DayPicker(stored: "2031-04-30") { _ in }) > 0)
    }

    @Test func everyCategoryHasItsGlyph() {
        #expect(ItemTemplates.categories.allSatisfy { ItemSymbols.category($0.id) != .folder || $0.id == "other" })
        #expect(ItemSymbols.category("loyalty_cards") == .folder)
    }
}

// swiftlint:enable line_length
#endif
