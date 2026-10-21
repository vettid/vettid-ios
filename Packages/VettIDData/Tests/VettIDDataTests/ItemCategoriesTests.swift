import Foundation
import Testing
@testable import VettIDData

/// Member-defined categories (VAULT-MESSAGING §10.7 `[a-z][a-z0-9_]{0,31}`): the identifier a typed name gives, and how
/// one is shown. Mirrors vettid-android `ItemCategoriesTest`.
@Suite struct ItemCategoriesTests {
    func id(_ name: String) -> String? { ItemCategories.derive(name).id }
    func problem(_ name: String) -> ItemCategories.Problem? { ItemCategories.derive(name).problem }

    @Test func aNameGivesALowerCaseIdentifier() {
        #expect(id("Loyalty cards") == "loyalty_cards")
        #expect(id("  Gym - membership  ") == "gym_membership")
        #expect(id("home-lab") == "home_lab")
        #expect(id("Pets & vets") == "pets_vets")
        #expect(id("Tickets!!!") == "tickets")
        #expect(id("a__b") == "a_b")
        #expect(id("Cars2") == "cars2")
    }

    @Test func accentsAreRemovedAndOtherScriptsDropped() {
        #expect(id("Café cards") == "cafe_cards")
        #expect(id("Straße") == "strasse")
        #expect(id("Notes 日本") == "notes")
        #expect(id("カード") == nil && problem("カード") == .empty)
    }

    @Test func emptyOrPunctuationOnlyGivesNone() {
        for name in ["", "   ", "--- !!", "___"] { #expect(problem(name) == .empty, "\(name)") }
    }

    @Test func anIdentifierStartsWithALetter() {
        #expect(problem("2fa codes") == .startsWithDigit && problem("_1 thing") == .startsWithDigit)
        #expect(id("-fa codes") == "fa_codes")
    }

    @Test func aLongNameIsCutTo32Characters() throws {
        let d = try #require(id("Very long category name that goes on and on"))
        #expect(d.count == 32 && d == "very_long_category_name_that_goe")
        // A cut that ends on a separator drops it.
        #expect(id(String(repeating: "a", count: 31) + " b") == String(repeating: "a", count: 31))
        #expect(ItemChecks.isValidCategory(try #require(id(String(repeating: "x", count: 100)))))
    }

    @Test func aRecommendedNameIsTheRecommendedCategory() {
        #expect(ItemCategories.derive("Payment card").recommended && id("Payment card") == "payment_card")
        #expect(!ItemCategories.derive("Loyalty cards").recommended)
    }

    @Test func aCustomCategoryIsHumanized() {
        #expect(ItemCategories.humanize("loyalty_cards") == "Loyalty cards")
        #expect(ItemCategories.humanize("cars2") == "Cars2" && ItemCategories.humanize("x") == "X")
    }

    @Test func customsAreTheMembersOwnDistinctAndSorted() {
        #expect(ItemCategories.customs(["login", "loyalty_cards", "gym", "loyalty_cards", "other", "Bad-Id"]) == ["gym", "loyalty_cards"])
    }
}
