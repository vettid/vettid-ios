import Testing
@testable import VettIDData
@testable import VettIDVault

/// VAULT-MESSAGING 0.76.0 §10.8 "Showing received text": breaks, trimming, empty text, summaries and the message bubble.
/// Mirrors vettid-android `AccountNamesTest` (0.76.0 section).
@Suite struct ReceivedTextTests {
    let fsi = "\u{2068}", pdi = "\u{2069}"

    @Test func breaksAreRecognisedInTheTextAsReceived() {
        // CR+LF is one break; CR, ZWSP, LF is two (the ZWSP is removed only afterwards).
        #expect(AccountNames.cleanedLines("a\r\nb") == "a\nb")
        #expect(AccountNames.cleanedLines("a\r\u{200B}\nb") == "a\n\nb")
        // VT and FF are breaks, not deleted.
        #expect(AccountNames.cleaned("a\u{000B}b") == "a b")
        #expect(AccountNames.cleaned("a\u{000C}b") == "a b")
        for br in ["\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}", "\r", "\n"] {
            #expect(AccountNames.cleanedLines("a\(br)b") == "a\nb", "\(br.unicodeScalars.map(\.value))")
        }
        #expect(AccountNames.cleaned("a\r\u{200B}\nb") == "a  b")
        #expect(AccountNames.cleaned("a\u{2028}b") == "a b")
    }

    @Test func keptLinesAreTrimmedPerLineWithNoEmptyLineAtEitherEnd() {
        #expect(AccountNames.cleanedLines("\n \u{00A0}\r\n  one \n\n\t two\u{3000}\n \n") == "one\n\ntwo")
        #expect(AccountNames.cleanedLines("\n \n") == nil)
    }

    @Test func overrideAndIsolateInsideTheTextAreRemoved() {
        #expect(AccountNames.cleaned("\u{202E}Bank") == "Bank")
        #expect(AccountNames.isolate("Ba\u{2069}nk\u{202E}") == "\(fsi)Bank\(pdi)")
        #expect(AccountNames.cleanedLines("Ban\u{2069}k\u{202E}?") == "Bank?")
    }

    @Test func nothingButIgnorablesAndWhiteSpaceIsEmptyYetStaysInTheShownText() {
        #expect(AccountNames.cleaned("\u{200D}") == nil)
        #expect(AccountNames.cleaned("\u{200C} \u{200D}") == nil)
        #expect(AccountNames.cleaned("\u{3164}") == nil)
        #expect(AccountNames.cleaned("\u{00A0}") == nil)
        #expect(AccountNames.isolateOrNull("\u{3164}\u{200D}\u{00A0}") == nil)
        #expect(AccountNames.cleanedLines("\u{3164}\n\u{200D}") == nil)
        #expect(AccountNames.cleaned("a\u{3164}") == "a\u{3164}")
        #expect(AccountNames.cleaned("a\u{200D}") == "a\u{200D}")
        #expect(AccountNames.isEmptyText("\u{3164}\u{200D} "))
        #expect(!AccountNames.isEmptyText("a"))
    }

    @Test func privateUseAndUnassignedCodePointsAreKept() {
        #expect(AccountNames.cleaned("a\u{E000}b") == "a\u{E000}b")
        #expect(AccountNames.cleaned("a\u{0378}b") == "a\u{0378}b")
        #expect(AccountNames.cleaned("a\u{F0000}b") == "a\u{F0000}b")
    }

    @Test func crAloneIsABreakSoftHyphenAndBomAreRemovedTabIsASpace() {
        #expect(AccountNames.cleanedLines("a\rb") == "a\nb")
        #expect(AccountNames.cleaned("a\rb") == "a b")
        #expect(AccountNames.cleaned("a\u{00AD}b\u{FEFF}") == "ab")
        #expect(AccountNames.cleaned("a\tb") == "a b")
        #expect(AccountNames.cleanedLines("a\tb") == "a b")
    }

    @Test func aSummaryTakesTheFirstNonEmptyLineAndIsolatesIt() {
        #expect(AccountNames.firstLineIsolated("\u{3164}\n\u{200D}\u{202E}\n real \nnext") == "\(fsi)real\(pdi)")
        #expect(AccountNames.firstLineIsolated("\u{3164}\n\u{200D}") == nil)
        #expect(AccountNames.firstLineIsolated(nil) == nil)
        #expect(AuthContext.firstLineIsolated("l1\nl2") == "\(fsi)l1\(pdi)")
        #expect(AuthContext.firstLineIsolated("\u{200B}\u{202E}\n\t\n \u{2069}") == nil)
        #expect(AuthContext.firstLineIsolated("") == nil)
    }

    @Test func keptLinesAreIsolatedLineByLine() {
        #expect(AccountNames.isolateLines("a\nb") == "\(fsi)a\(pdi)\n\(fsi)b\(pdi)")
        #expect(AuthContext.isolated("l1\u{202E}\nl2") == "\(fsi)l1\(pdi)\n\(fsi)l2\(pdi)")
        #expect(AuthContext.isolated(" \u{202E} ") == nil)
        #expect(AuthContext.isolated("\u{3164}") == nil)
        #expect(AuthContext.plain("\u{3164}\u{200D}") == "")
    }

    @Test func aMessageBubbleKeepsDirectionalMarksOnly() {
        // RLM, LRM, ALM kept; RLO and the isolates removed; ZWSP removed; ZWJ kept.
        let raw = "a\u{200F}b\u{200E}\u{202E}c\u{061C}\u{2069}d\u{200B}\u{200D}e"
        #expect(AccountNames.cleanedMessage(raw) == "a\u{200F}b\u{200E}c\u{061C}d\u{200D}e")
        // Breaks as LF; only the ends of the whole text are trimmed, so indentation stays.
        #expect(AccountNames.cleanedMessage("\n\r\n  a\u{2028}  b \u{000B}\n") == "a\n  b")
        #expect(AccountNames.cleanedMessage("a\r\u{200B}\nb") == "a\n\nb")
        #expect(AccountNames.cleanedMessage("\u{3164} \u{200D}") == "")
        #expect(AccountNames.cleanedMessage(nil) == "")
        #expect(AuthContext.bubble("\n a\u{200F}\u{202E}b\r\nc \u{2028}") == "\(fsi)a\u{200F}b\(pdi)\n\(fsi)c\(pdi)")
        #expect(AuthContext.bubble("\u{200B}\u{3164}") == "")
    }

    /// A name of NBSP only, ZWJ only or U+3164 only has nothing to show: callers fall back to their placeholder.
    @Test func hostileNamesAreEmpty() {
        for hostile in ["\u{00A0}", "\u{200D}", "\u{3164}", "\r\u{200B}\n", "\u{000B}\u{000C}"] {
            #expect(AccountNames.isolateOrNull(hostile) == nil, "\(hostile.unicodeScalars.map(\.value))")
            #expect(AccountNames.cleaned(hostile) == nil)
        }
    }

    /// An attachment's file name (§10.5.1) is shown cleaned, cut at a grapheme boundary and left out when empty.
    @Test func aCappedNameCutsAtAGraphemeBoundaryAndLeavesNoTrailingSpace() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(AccountNames.cleanedCapped("a" + family, max: 4) == "a")
        #expect(AccountNames.cleanedCapped("a" + family, max: 8) == "a" + family)
        #expect(AccountNames.cleanedCapped(String(repeating: "x", count: 63) + " yy", max: 64) == String(repeating: "x", count: 63))
        #expect(AccountNames.cleanedCapped("\u{202E}x\u{202E}x", max: 64) == "xx")
        #expect(AccountNames.cleanedCapped("\u{3164}", max: 64) == nil)
        #expect(AccountNames.cleanedCapped("photo\u{202E}gpj.exe\r\n", max: 64) == "photogpj.exe")
    }

    /// An attachment's name (§10.5.1) as the device view shows it: cleaned and cut at 64, and, chosen (not in the spec),
    /// without path separators or leading dots.
    @Test func anAttachmentNameIsShownCleanedWithoutPathParts() {
        func shown(_ name: String?) -> String? {
            AttachmentInfo.of(AttachmentView(
                attID: "a", kind: "photo", mime: nil, size: 1, width: 1, height: 1, name: name, state: "stored", reason: nil, thumb: nil
            )).name
        }
        #expect(shown("../../etc/passwd") == "etcpasswd")
        #expect(shown("photo\u{202E}gpj.exe") == "photogpj.exe")
        #expect(shown("...hidden") == "hidden")
        #expect(shown("windows\\file") == "windowsfile")
        #expect(shown("a\u{0}\u{7}\nb") == "a b")
        #expect(shown("\u{202E}/\\..") == nil)
        #expect(shown("\u{3164}") == nil && shown(nil) == nil)
        #expect(shown(String(repeating: "x", count: 300))?.count == 64)
        // Code points, never cut inside a grapheme cluster.
        #expect(shown(String(repeating: "\u{1F4F7}", count: 70))?.unicodeScalars.count == 64)
    }
}
