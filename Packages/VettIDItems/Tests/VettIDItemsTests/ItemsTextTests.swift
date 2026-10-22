import Foundation
import Testing
import VettIDData
@testable import VettIDItems

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Vault's texts: every key of vettid-android's `feature/items` `strings.xml` (277 strings) and `strings_sharing.xml`
/// (158 strings, 24 plurals) resolves to its own text (0.55.0 adds `items_phone_extension_note` and the plural
/// `items_share_preview_more`; the iPhone's two secret-item texts are `ios_items_…`), and the tags screen's words.
@Suite struct ItemsTextTests {
    @Test func everyStringResolves() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VettIDItems/Resources/Localizable.xcstrings")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(doc["strings"] as? [String: Any])
        let expected = 277 + 158 + 24 + 2
        #expect(strings.count == expected)
        let missing = "\u{0}missing"
        for key in strings.keys {
            let text = ItemsStrings.bundle.localizedString(forKey: key, value: missing, table: nil)
            #expect(!text.isEmpty && text != key && text != missing, "\(key)")
            let named = key.hasPrefix("items_") || key.hasPrefix("ios_items_")
            #expect(named, "\(key)")
        }
    }

    @Test func theTagsScreensWords() {
        #expect(ItemsText.tagLabel("@profile") == "Shared profile" && ItemsText.tagLabel("travel") == "travel")
        #expect(ItemsStrings.tagsRenameTitle("health", "medical") == "Rename health to medical?")
        #expect(ItemsStrings.tagItems(1) == "1 item" && ItemsStrings.tagItems(3) == "3 items")
        #expect(ItemsText.tagCounts(TagView(tag: "medical", items: 3, rules: ["r1"])) == "3 items · used by 1 sharing rule")
        #expect(ItemsText.tagSupporting(TagView(tag: "travel", items: 1, description: "Trips")) == "1 item · Trips")
        #expect(ItemsText.tagSupporting(TagView(tag: "@profile", items: 2)) == "Every connection sees these items in your profile")
        #expect(ItemsText.colourNames == ["Red", "Orange", "Green", "Teal", "Blue", "Indigo", "Violet", "Pink", "Brown", "Slate"])
        #expect(ItemsStrings.tagsCdColourSelected("Teal") == "Teal, selected")
    }

    @Test func aChangeSaysWhatItSharesAndAsks() {
        let c = TagChange(version: 3, items: 2, shares: [SharePreview(ruleID: "r1", itemID: "i1", mode: .auto), SharePreview(ruleID: "r2", itemID: "i2", mode: .ask)], sharesTotal: 3)
        #expect(ItemsText.change(c, renaming: true) == "This changes 2 items. 1 item is then shared automatically. You will be asked about sharing 1 item. 1 more may be shared.")
        // Entries beyond the listed ones are not counted as asked (§10.8, 0.55.0): only said to be possibly shared.
        let listed = TagChange(version: 3, items: 2, shares: [SharePreview(ruleID: "r2", itemID: "i2", mode: .ask)], sharesTotal: 5)
        #expect(ItemsText.change(listed, renaming: true) == "This changes 2 items. You will be asked about sharing 1 item. 4 more may be shared.")
        let all = TagChange(version: 3, items: 1, shares: [SharePreview(ruleID: "r1", itemID: "i1", mode: .auto)], sharesTotal: 1)
        #expect(ItemsText.change(all, renaming: true) == "This changes 1 item. 1 item is then shared automatically.")
        #expect(ItemsText.change(c, renaming: false) == "This changes 2 items.")
        #expect(ItemsText.change(TagChange(version: 1, items: 1), renaming: true) == "This changes 1 item.")
        // An `auto` share an `ask` rule holds back (§10.8, 0.23.1 `ask_rule_id`) is asked about, not automatic.
        let held = TagChange(version: 4, items: 1, shares: [SharePreview(ruleID: "r1", itemID: "i1", mode: .auto, askRuleID: "r9"), SharePreview(ruleID: "r2", itemID: "i2", mode: .auto)], sharesTotal: 2)
        #expect(ItemsText.change(held, renaming: true) == "This changes 1 item. 1 item is then shared automatically. You will be asked about sharing 1 item.")
    }

    @Test func failuresInTheVaultsWords() {
        #expect(ItemsText.failure(.limit, limit: VaultLimit("tag_registry", max: 512)) == VaultLimit("tag_registry", max: 512).message)
        #expect(ItemsText.failure(.limit, creating: true) == "Your vault is full: it holds at most 2,000 items")
        #expect(ItemsText.failure(.limit, creating: true, critical: true) == "Your credential is full: it holds at most 1,000 critical items")
        #expect(ItemsText.failure(.limit, profile: true) == "Your shared profile is full: at most 32 items, within its size limit")
        #expect(ItemsText.failure(.limit) == "A limit of your vault would be exceeded")
        #expect(ItemsText.failure(.conflict).hasPrefix("This item was changed on another device"))
        #expect(ItemsText.failure(.other, shownCode: "bad_request") == "Your vault refused this item. Check its fields and try again.")
        #expect(ItemsText.failure(.other, shownCode: "zebra") == FailureKind.vaultCode("zebra").message)
        #expect(ItemsText.failure(.network) == FailureKind.network.message)
    }
}

// swiftlint:enable line_length
