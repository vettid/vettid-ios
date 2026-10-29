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

    // A received name in a sentence (§10.8): the one cleaning step. Mirrors vettid-android #220's `AccountNamesTest`.
    let fsi = "\u{2068}", pdi = "\u{2069}"

    @Test func everyBidiControlIsRemovedFromAReceivedName() {
        let controls = [
            ("LRE", "\u{202A}"), ("RLE", "\u{202B}"), ("PDF", "\u{202C}"), ("LRO", "\u{202D}"), ("RLO", "\u{202E}"),
            ("LRI", "\u{2066}"), ("RLI", "\u{2067}"), ("FSI", "\u{2068}"), ("PDI", "\u{2069}"),
            ("LRM", "\u{200E}"), ("RLM", "\u{200F}"), ("ALM", "\u{061C}"),
        ]
        for (label, c) in controls {
            #expect(AccountNames.isolate("Ada\(c)King") == "\(fsi)AdaKing\(pdi)", "\(label)")
            #expect(AccountNames.cleaned("\(c)Ada\(c)King\(c)") == "AdaKing", "\(label)")
        }
    }

    @Test func zeroWidthByteOrderMarkAndTagCharactersAreRemoved() {
        #expect(AccountNames.cleaned("Ada\u{200B}King") == "AdaKing")
        #expect(AccountNames.cleaned("\u{FEFF}AdaKing") == "AdaKing")
        #expect(AccountNames.cleaned("A\u{E0020}d\u{E0041}a\u{E007F}") == "Ada")
    }

    @Test func lineBreaksBecomeSpacesAndTheNameIsTrimmed() {
        for br in ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}", "\u{0085}", "\t"] {
            #expect(AccountNames.isolate("Ada\(br)King") == "\(fsi)Ada King\(pdi)", "\(br.unicodeScalars.map(\.value))")
        }
        #expect(AccountNames.isolate("\n  Ada \u{2029}") == "\(fsi)Ada\(pdi)")
    }

    @Test func zwjAndZwnjAreKept() {
        #expect(AccountNames.isolate("👩\u{200D}💻") == "\(fsi)👩\u{200D}💻\(pdi)")
        #expect(AccountNames.isolate("می\u{200C}خواهم") == "\(fsi)می\u{200C}خواهم\(pdi)")
    }

    @Test func nothingLeftIsNilAndIsolationIsIdempotent() {
        #expect(AccountNames.isolateOrNull(nil) == nil)
        #expect(AccountNames.isolateOrNull("") == nil)
        #expect(AccountNames.isolateOrNull(" \u{202E}\u{202C}\u{200B}\n ") == nil)
        #expect(AccountNames.isolate("\u{202E}") == fsi + pdi)
        let once = AccountNames.isolate("Bank")
        #expect(AccountNames.isolate(once) == once)
        #expect(AccountNames.cleaned(once) == "Bank")
    }

    @Test func aClosingIsolateCannotEscapeAndReverseTheFixedWords() {
        let out = AccountNames.isolate("Bank\(pdi)\u{202E}")
        #expect(out == "\(fsi)Bank\(pdi)")
        #expect(out.unicodeScalars.filter { $0 == "\u{2069}" }.count == 1)
    }

    @Test func aNameOfOnlyFormatCharactersIsNilSoCallersKeepTheirFallback() {
        #expect(AccountNames.isolateOrNull("\u{200B}\u{202E}\u{FEFF}") == nil)
        #expect(AccountNames.cleaned("\u{200B}\u{202E}\u{FEFF}") == nil)
    }

    /// All Unicode white space trims, as Kotlin's `trim()` does: NBSP, EM SPACE and IDEOGRAPHIC SPACE alone leave nothing.
    @Test func aNameOfOnlyUnicodeWhiteSpaceIsNil() {
        for blank in ["\u{00A0}", "\u{2003}", "\u{3000}", " \u{00A0}\u{2003}\u{3000}\t"] {
            #expect(AccountNames.isolateOrNull(blank) == nil && AccountNames.cleaned(blank) == nil, "\(blank.unicodeScalars.map(\.value))")
        }
        #expect(AccountNames.cleaned("\u{3000}Ada\u{00A0}") == "Ada")
    }

    /// The auth context keeps its lines (§10.4, shown in full) but loses every control and format character.
    @Test func theAuthContextKeepsItsLinesAndLosesTheOverrides() {
        let note = "Sign in\r\nto Bank\u{2069}\u{202E}\u{2028}now\t!"
        #expect(AuthContext.plain(note) == "Sign in\nto Bank\nnow !")
        #expect(AuthContext.isolated(note) == "\(fsi)Sign in\nto Bank\nnow !\(pdi)")
        #expect(AuthContext.isolated("\u{200B}\u{202E}\n ") == nil)
    }
}
