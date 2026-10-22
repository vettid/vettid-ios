import CryptoKit
import Foundation
import Testing
import VettIDData
@testable import VettIDItems

/// ``ItemTemplates`` against vettid-vault's registry (`docs/item-templates.json`, format 1, version 3; Resources/SOURCE.md):
/// the same categories with their icons, the same templates in the same order with their category, sensitivity, tags and
/// fields (label, kind, `"format": "month"`). The labels are the English defaults the app's strings give.
@MainActor
@Suite struct ItemTemplatesRegistryTests {
    private func registry() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "item-templates", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(sha == "aa5af254f548ef5a20d76f42b6b4615c1950f9eef41a2f34a1634d83506ef7b1")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theCopyIsVersion3() throws {
        let r = try registry()
        #expect(r["format"] as? Int == 1 && r["version"] as? Int == 3)
    }

    @Test func theCategoriesAreTheRegistrys() throws {
        let cats = try #require(try registry()["categories"] as? [[String: String]])
        #expect(ItemTemplates.categories.map(\.id) == cats.map { $0["category"] ?? "" })
        #expect(ItemTemplates.categories.map(\.icon) == cats.map { $0["icon"] ?? "" })
        #expect(ItemTemplates.categories.map(\.label) == cats.map { $0["label"] ?? "" })
        #expect(ItemTemplates.categories.map(\.id) == ItemChecks.recommendedCategories)
    }

    @Test func theTemplatesAreTheRegistrys() throws {
        let ts = try #require(try registry()["templates"] as? [[String: Any]])
        #expect(ItemTemplates.all.map(\.id) == ts.map { $0["template"] as? String ?? "" })
        for (t, j) in zip(ItemTemplates.all, ts) {
            #expect(t.name == j["name"] as? String, "\(t.id)")
            #expect(t.category == j["category"] as? String, "\(t.id)")
            #expect(t.sensitivity.rawValue == j["sensitivity"] as? String, "\(t.id)")
            #expect(t.tags == j["tags"] as? [String], "\(t.id)")
            let fields = try #require(j["fields"] as? [[String: String]])
            #expect(t.fields.map(\.label) == fields.map { $0["label"] ?? "" }, "\(t.id)")
            #expect(t.fields.map(\.kind) == fields.map { $0["kind"] ?? "" }, "\(t.id)")
            #expect(t.fields.map(\.format) == fields.map { $0["format"] }, "\(t.id)")
        }
    }
}
