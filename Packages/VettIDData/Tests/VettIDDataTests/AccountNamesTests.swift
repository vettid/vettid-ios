import Testing
import VettIDData

/// The registration rule for a requested name and the receiver's rule for core names (VAULT-MESSAGING §10.8). Mirrors
/// vettid-android `AccountNamesTest`.
@Suite struct AccountNamesTests {
    @Test func registrationRule() {
        for ok in ["Ada", "King", "O'Brien", "O’Brien", "Jean-Luc", "St. John", "Zoë", "José", "Łukasz", "李", "Anne Marie"] {
            #expect(AccountNames.check(ok) == .ok, "\(ok)")
            #expect(AccountNames.normalize(ok) == ok, "\(ok)")
        }
        // A letter and a combining mark (Zoë decomposed).
        #expect(AccountNames.check("Zoe\u{0308}") == .ok)
        // Trimmed of U+0020 only.
        #expect(AccountNames.normalize("  Ada ") == "Ada")
        #expect(AccountNames.check("\tAda") == .invalid)
        #expect(AccountNames.check("Ada\u{00A0}") == .invalid)
        #expect(AccountNames.check("Ada\n") == .invalid)
        // The first character is a letter (or mark); then letters, marks, spaces and '’.-
        #expect(AccountNames.check("-Ada") == .invalid)
        #expect(AccountNames.check("'Ada") == .invalid)
        #expect(AccountNames.check("Ada1") == .invalid)
        #expect(AccountNames.check("Ada_King") == .invalid)
        #expect(AccountNames.check("Ada@") == .invalid)
        #expect(AccountNames.check("") == .empty)
        #expect(AccountNames.check("   ") == .empty)
        #expect(AccountNames.normalize("   ") == nil)
        // At most 40 UTF-16 code units, counted after trimming.
        #expect(AccountNames.check(String(repeating: "a", count: 40)) == .ok)
        #expect(AccountNames.check(" " + String(repeating: "a", count: 40) + " ") == .ok)
        #expect(AccountNames.check(String(repeating: "a", count: 41)) == .tooLong)
        // A supplementary letter counts as two units.
        let gothic = "\u{10330}"
        #expect(AccountNames.check(String(repeating: gothic, count: 20)) == .ok)
        #expect(AccountNames.check(String(repeating: gothic, count: 20) + "a") == .tooLong)
    }

    @Test func coreRule() {
        #expect(AccountNames.isValidCore("Ada"))
        #expect(AccountNames.isValidCore(String(repeating: "a", count: 160)))
        #expect(!AccountNames.isValidCore(String(repeating: "a", count: 161)))
        #expect(AccountNames.isValidCore(String(repeating: "é", count: 80))) // 160 bytes
        #expect(!AccountNames.isValidCore(String(repeating: "é", count: 80) + "a"))
        #expect(!AccountNames.isValidCore(""))
        #expect(!AccountNames.isValidCore(nil))
        // (A lone surrogate, Android's last case, cannot be put in a Swift string.)
        for bad in ["\u{0000}", "\u{001F}", "\u{0080}", "\u{009F}", "\u{2028}", "\u{2029}"] {
            #expect(!AccountNames.isValidCore("Ada\(bad)"), "\(bad.unicodeScalars.first!.value)")
        }
        // Not the registration rule: the receiver takes what the snapshot carries.
        #expect(AccountNames.isValidCore("Ada 2"))
        #expect(AccountNames.isValidCore("Ada\u{007F}"))
    }

    @Test func fullNameAndIsolation() {
        #expect(AccountNames.full("Ada", "King") == "Ada King")
        #expect(AccountNames.full("Ada", nil) == nil)
        #expect(AccountNames.full("", "King") == nil)
        #expect(AccountNames.isolate("Ada King") == "\u{2068}Ada King\u{2069}")
    }

    @Test func emailFormat() {
        #expect(EmailFormat.isPlausible("ada@example.org"))
        #expect(EmailFormat.isPlausible(" ada@example.org\n"))
        #expect(!EmailFormat.isPlausible("ada@example"))
        #expect(!EmailFormat.isPlausible("ada@example.o"))
        #expect(!EmailFormat.isPlausible("ada@@example.org"))
        #expect(!EmailFormat.isPlausible("a da@example.org"))
        #expect(!EmailFormat.isPlausible(String(repeating: "a", count: 65) + "@example.org"))
        #expect(!EmailFormat.isPlausible("a@" + String(repeating: "b", count: 250) + ".org"))
    }
}
