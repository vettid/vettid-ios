import Foundation
import Testing
@testable import VettIDCrypto

// Value tables stay on one line each.
// swiftlint:disable line_length

/// The shape of items (VAULT-MESSAGING §10.7, §10.8): the cases of vettid-vault's `features/itemspec` tests
/// (`TestNormalizeTag`, `TestParseTags`, `TestParseValue`) and of vettid-android's `CredentialAndItemsTest.itemShapes`.
@Suite struct ItemSpecTests {
    @Test func tagsAreNormalisedAsTheVaultDoes() throws {
        let ok = [
            "Travel": "travel", "  Dr  Lee  ": "dr lee", "tax-2026": "tax-2026", "a_b": "a_b", "0": "0",
            "MEDICAL  NOTES": "medical notes", String(repeating: "x", count: 32): String(repeating: "x", count: 32),
            "  Travel   Plans ": "travel plans",
        ]
        for (input, want) in ok { #expect(try ItemSpec.normalizeTag(input) == want, "\(input)") }
        let bad = ["", "  ", "-a", "_a", " a!", "é", "a\tb", String(repeating: "x", count: 33), "@profile", "@other", "a,b", "a.b"]
        for input in bad { #expect(throws: CryptoError.self, "\(input)") { try ItemSpec.normalizeTag(input) } }
        #expect(try ItemSpec.normalizeTag("@Profile", reserved: true) == ItemSpec.profileTag)
        #expect(throws: CryptoError.self) { try ItemSpec.normalizeTag("@other", reserved: true) }
        #expect(throws: CryptoError.self) { try ItemSpec.normalizeTag(String(repeating: "a", count: 129)) }
    }

    @Test func tagListsAreSortedWithoutDuplicatesAndAtMost16() throws {
        #expect(try ItemSpec.normalizeTags(["Travel", "identity", "travel", " ID  card "]) == ["id card", "identity", "travel"])
        #expect(try ItemSpec.normalizeTags(["B", "a", "b"]) == ["a", "b"])
        #expect(throws: CryptoError.self) { try ItemSpec.normalizeTags((0..<17).map { "t\($0)" }) }
    }

    @Test func stringValuesFollowTheirKind() {
        let good: [String: [String]] = [
            ItemSpec.kindText: ["", "hello", "tab-free text"],
            ItemSpec.kindMultiline: ["a\nb\tc"],
            ItemSpec.kindPassword: ["p\tw\nd"],
            ItemSpec.kindNumber: ["42", "-3.14", "0.5", "-12.50"],
            ItemSpec.kindDate: ["2031-04-30", "2031-04", "2024-02-29", "2000-02-29"],
            ItemSpec.kindEmail: ["a@b.c", "first.last+tag@example.org", "a@b"],
            ItemSpec.kindPhone: ["+1 (555) 010-0100", "112"],
            ItemSpec.kindURL: ["https://example.org/x?y=1", "mailto:a@b.c", "https://x.org/a", "https://[::1]:8443/p", "http://h:80"],
            ItemSpec.kindOTP: ["JBSWY3DPEHPK3PXP", "jbswy3dpehpk3pxp", "JBSWY3DPEHPK3PXP====", "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"],
        ]
        for (kind, values) in good {
            for v in values { #expect(ItemSpec.isValidStringValue(kind, v), "\(kind) \(v)") }
        }
        let bad: [String: [String]] = [
            ItemSpec.kindText: ["a\nb", "a\u{0}"],
            ItemSpec.kindNumber: ["1e5", "1.", "abc", "--1", "1e3", "1,5"],
            ItemSpec.kindDate: ["2031-13-01", "2023-02-29", "31-04-2031", "2031-4-30", "2031-02-30", "1900-02-29", "2031-00"],
            ItemSpec.kindEmail: ["no-at", "a@", "@b", "a b@c", "a@b@c", "a@@b"],
            ItemSpec.kindPhone: ["call me", "+-()", "()", String(repeating: "1", count: 33)],
            ItemSpec.kindURL: ["/relative", "https://a b", "example.org", "x.org", ":x", "https://h:port/", "http://a/%zz"],
            ItemSpec.kindOTP: ["SHORT", "JBSWY3DPEHPK3PX1", "otpauth://x y", "JBSWY3DPEHPK3PXP======="],
            ItemSpec.kindFile: ["blob", "x"],
            "nonsense": ["x"],
            ItemSpec.kindPassword: ["a\u{1}"],
        ]
        for (kind, values) in bad {
            for v in values { #expect(!ItemSpec.isValidStringValue(kind, v), "\(kind) \(v)") }
        }
        #expect(!ItemSpec.isValidStringValue(ItemSpec.kindMultiline, String(repeating: "x", count: ItemSpec.maxValue + 1)))
        // Every kind accepts "" (not filled in); the reserved file kind does not.
        for kind in ItemSpec.kinds { #expect(ItemSpec.isValidStringValue(kind, "") || kind == ItemSpec.kindAddress) }
        #expect(!ItemSpec.isValidStringValue(ItemSpec.kindFile, ""))
    }

    @Test func valuesHaveTheVaultsCanonicalForm() throws {
        func value(_ json: String) throws -> JsonValue { try #require(StrictJson.parseObject(#"{"v":\#(json)}"#)["v"]) }
        #expect(try ItemSpec.canonicalValue(ItemSpec.kindAddress, value(#"{"country":"NO","city":"Oslo","street":""}"#)) == #"{"city":"Oslo","country":"NO"}"#)
        #expect(try ItemSpec.canonicalValue(ItemSpec.kindAddress, value("{}")) == "{}")
        #expect(try ItemSpec.canonicalValue(ItemSpec.kindText, value(#""<&>""#)) == #""<&>""#)
        #expect(try ItemSpec.canonicalValue(ItemSpec.kindMultiline, value(#""a\u2028b""#)) == #""a\u2028b""#)
        for bad in [#"{"city":1}"#, #"{"planet":"Mars"}"#, #"{"country":"nor"}"#, #"{"country":"no"}"#, #"{"city":"a\nb"}"#, #""Oslo""#] {
            #expect(throws: CryptoError.self, "\(bad)") { try ItemSpec.canonicalValue(ItemSpec.kindAddress, try value(bad)) }
        }
        for (kind, bad) in [(ItemSpec.kindText, "1"), (ItemSpec.kindText, "null"), (ItemSpec.kindFile, #""blob""#), (ItemSpec.kindDate, #""tomorrow""#)] {
            #expect(throws: CryptoError.self, "\(kind) \(bad)") { try ItemSpec.canonicalValue(kind, try value(bad)) }
        }
    }

    @Test func namesLabelsCategoriesTemplatesAndFieldIDs() {
        #expect(ItemSpec.isValidName(String(repeating: "x", count: 128)) && !ItemSpec.isValidName(String(repeating: "é", count: 65)))
        #expect(!ItemSpec.isValidName("") && !ItemSpec.isValidName("a\u{7F}b") && !ItemSpec.isValidName("a\nb"))
        #expect(ItemSpec.isValidLabel("Number") && !ItemSpec.isValidLabel(String(repeating: "x", count: 65)))
        #expect(ItemSpec.isValidNotes("a\nb\tc") && !ItemSpec.isValidNotes("a\rb"))
        #expect(ItemSpec.isValidCategory("identity_document") && ItemSpec.isValidCategory("x") && ItemSpec.isValidCategory(String(repeating: "a", count: 32)))
        #expect(!ItemSpec.isValidCategory("Bad") && !ItemSpec.isValidCategory("_a") && !ItemSpec.isValidCategory("1a") && !ItemSpec.isValidCategory(String(repeating: "a", count: 33)))
        #expect(ItemSpec.isValidTemplate("passport") && ItemSpec.isValidTemplate("email_address.v2-x") && !ItemSpec.isValidTemplate("Passport"))
        #expect(ItemSpec.isValidFieldID("f12") && ItemSpec.isValidFieldID("A_b-1") && !ItemSpec.isValidFieldID("f 1") && !ItemSpec.isValidFieldID(""))
        #expect(ItemSpec.recommendedCategories.allSatisfy(ItemSpec.isValidCategory))
        #expect(ItemSpec.isValidSensitivity("critical") && !ItemSpec.isValidSensitivity("Critical"))
    }
}

// swiftlint:enable line_length
