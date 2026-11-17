import Foundation

/// A string of an approval's document as the screen shows it (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents",
/// "Text"): plain text, never markup or links, in which every character that could reorder, hide or imitate other text
/// is a visible marker naming its code point (`⟨U+202E⟩`), never applied. The rules replace §10.8 "Showing received
/// text" on this screen.
public struct ShownText: Equatable, Sendable {
    public enum Run: Equatable, Sendable {
        /// Characters shown as themselves.
        case text(String)
        /// A kept line break (LF), only where the field keeps them.
        case lineBreak
        /// A character shown as its code point, never applied.
        case marker(UInt32)
    }

    public var runs: [Run]

    /// The marker of [scalar]: `⟨U+202E⟩` (at least four hex digits, upper case).
    public static func marker(_ scalar: UInt32) -> String { "⟨U+" + String(format: "%04X", scalar) + "⟩" }

    /// The text as one string, markers written out and kept line breaks as LF: what the screen draws, before the
    /// isolation each block adds.
    public var plain: String {
        runs.map { run -> String in
            switch run {
            case .text(let s): s
            case .lineBreak: "\n"
            case .marker(let v): Self.marker(v)
            }
        }.joined()
    }

    /// Whether nothing is shown (an empty string).
    public var isEmpty: Bool { runs.isEmpty }

    /// [s] cleaned. [lineBreaks]: the field keeps line breaks (Motion and Quorum's text): at most two LF in a row are
    /// kept, a third and later in a row are markers; elsewhere every LF is a marker. [escaped]: a string of the raw view,
    /// whose `"` and `\` are shown escaped as JSON writes them (`\"`, `\\`), so that no string can close its own quotes
    /// and draw what looks like another member (chosen; not in the spec).
    public init(_ s: String, lineBreaks: Bool = false, escaped: Bool = false) {
        var runs: [Run] = []
        var text = String.UnicodeScalarView()
        var breaks = 0
        var marks = 0
        func flush() {
            if !text.isEmpty { runs.append(.text(String(text))) }
            text = String.UnicodeScalarView()
        }
        for scalar in s.unicodeScalars {
            let isBreak = scalar == "\n"
            breaks = isBreak ? breaks + 1 : 0
            let isMark = [.nonspacingMark, .enclosingMark].contains(scalar.properties.generalCategory)
            marks = isMark ? marks + 1 : 0
            // A combining mark with no base of its own in this run (at the start, or after a marker or a line break)
            // would combine with what the app draws before it (a quotation mark, a marker): a marker itself; a spacing
            // mark (Mc) as well.
            let baseless = (isMark || scalar.properties.generalCategory == .spacingMark) && text.isEmpty
            if isBreak, lineBreaks, breaks <= 2 {
                flush()
                runs.append(.lineBreak)
            } else if isBreak || Self.marked(scalar) || (isMark && marks > 2) || baseless {
                flush()
                runs.append(.marker(scalar.value))
            } else if escaped, scalar == "\"" || scalar == "\\" {
                text.append("\\")
                text.append(scalar)
            } else {
                text.append(scalar)
            }
        }
        flush()
        self.runs = runs
    }

    /// The characters always shown as markers: control (Cc, U+0085 included) and format (Cf, the bidirectional controls
    /// among them) characters, line and paragraph separators (Zl, Zp), private-use and unassigned code points (Co, Cn: a
    /// character newer than this system's Unicode data is unassigned to it), any other Default_Ignorable_Code_Point (the
    /// Hangul fillers, the variation selectors, U+FE0F and the joiners among them), and every space separator (Zs) but
    /// U+0020. Also (chosen; not in the spec) the brackets markers are drawn with, U+27E8 and U+27E9, and their look-alikes,
    /// so that no text can spell a marker, however it is styled.
    /// ⟨ ⟩ and the angle brackets that look like them: 〈 〉 (U+2329, U+232A), 〈 〉 (U+3008, U+3009), ❬ ❭ (U+276C, U+276D),
    /// ‹ › (U+2039, U+203A), ❮ ❯ (U+276E, U+276F), ⟪ ⟫ (U+27EA, U+27EB), ＜ ＞ (U+FF1C, U+FF1E), ⧼ ⧽ (U+29FC, U+29FD),
    /// ⦑ ⦒ (U+2991, U+2992), and the blank glyphs that are not default-ignorable: U+2800 BRAILLE PATTERN BLANK and U+FFFC
    /// OBJECT REPLACEMENT CHARACTER.
    static let markerBrackets: Set<UInt32> = [
        0x27E8, 0x27E9, 0x2329, 0x232A, 0x3008, 0x3009, 0x276C, 0x276D, 0x2039, 0x203A, 0x276E, 0x276F, 0x27EA, 0x27EB,
        0xFF1C, 0xFF1E, 0x29FC, 0x29FD, 0x2991, 0x2992, 0x2800, 0xFFFC,
    ]

    static func marked(_ scalar: Unicode.Scalar) -> Bool {
        if markerBrackets.contains(scalar.value) { return true }
        let p = scalar.properties
        switch p.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: return true
        case .spaceSeparator: return scalar != " "
        default: return p.isDefaultIgnorableCodePoint
        }
    }
}
