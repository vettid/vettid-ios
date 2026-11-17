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

    init(runs: [Run]) { self.runs = runs }

    /// At most this many characters to a piece (``pieces(max:maxBreaks:)``).
    public static let pieceCharacters = 200

    /// A piece of a value: its text, and whether it goes on from the piece before (cut inside a paragraph) rather than
    /// starting a paragraph of its own (after a kept line break) or the value.
    public struct Piece: Equatable, Sendable {
        public var text: ShownText
        public var continues: Bool
    }

    /// The text in pieces of at most [max] characters and [maxBreaks] kept line breaks, each drawn as a row of its own: a
    /// single text of tens of kilobytes is drawn blank on an iPhone, and drawn whole it takes more memory than an app may
    /// hold. A piece ends after a white space where there is one, at a kept line break once it is half full (the break
    /// between pieces is that line break, and the next piece starts a paragraph), never inside a marker, else at the
    /// bound. (One case per kind of run, and the cut of a text run in place.)
    public func pieces(max: Int = Self.pieceCharacters, maxBreaks: Int = .max) -> [Piece] { // swiftlint:disable:this cyclomatic_complexity
        var out: [Piece] = []
        var cur: [Run] = []
        var n = 0
        var breaks = 0
        var continues = false
        func close(paragraph: Bool) {
            out.append(Piece(text: ShownText(runs: cur), continues: continues))
            cur = []
            n = 0
            breaks = 0
            continues = !paragraph
        }
        for run in runs {
            switch run {
            case .marker(let v):
                let len = Self.marker(v).count
                if n > 0, n + len > max { close(paragraph: false) }
                cur.append(run)
                n += len
            case .lineBreak:
                if n >= max / 2 || breaks >= maxBreaks { close(paragraph: true) } else {
                    cur.append(run)
                    n += 1
                    breaks += 1
                }
            case .text(let s):
                var rest = Substring(s)
                while !rest.isEmpty {
                    guard let limit = rest.index(rest.startIndex, offsetBy: max - n, limitedBy: rest.endIndex), limit < rest.endIndex
                    else {
                        n += rest.count
                        cur.append(.text(String(rest)))
                        break
                    }
                    var cut = limit
                    if let ws = rest[..<limit].lastIndex(where: \.isWhitespace) {
                        cut = rest.index(after: ws)
                    } else if n > 0 {
                        close(paragraph: false)
                        continue
                    }
                    if cut > rest.startIndex { cur.append(.text(String(rest[..<cut]))) }
                    rest = rest[cut...]
                    close(paragraph: false)
                }
            }
        }
        if !cur.isEmpty || out.isEmpty { close(paragraph: true) }
        return out
    }

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
        func marker(_ scalar: Unicode.Scalar) {
            flush()
            runs.append(.marker(scalar.value))
        }
        // Character by character, so that no character (grapheme cluster) is drawn with more than ``maxClusterScalars``
        // code points: past them, each is a marker (chosen; not in the spec). A cluster has no length limit of its own
        // (a run of Hangul leading jamo, a base with thousands of marks), and one that long would be one text too tall to
        // draw.
        for ch in s {
            for (k, scalar) in ch.unicodeScalars.enumerated() {
                let isBreak = scalar == "\n"
                breaks = isBreak ? breaks + 1 : 0
                let p = scalar.properties
                // The row §10.4 counts: combining and enclosing marks (Mn, Me). Spacing marks (Mc) do not stack (ordinary
                // Burmese has three in a row); the code-point cap bounds every cluster.
                let isMark = [.nonspacingMark, .enclosingMark].contains(p.generalCategory)
                marks = isMark ? marks + 1 : 0
                // A mark of any kind with no base of its own in this run (at the start, or after a marker or a line break)
                // would combine with what the app draws before it (a quotation mark, a marker): a marker itself; and an
                // emoji skin-tone modifier with no base would tint it.
                let extender = isMark || p.generalCategory == .spacingMark || p.isGraphemeExtend
                let baseless = (extender || p.isEmojiModifier) && text.isEmpty
                if isBreak, lineBreaks, breaks <= 2 {
                    flush()
                    runs.append(.lineBreak)
                } else if isBreak || Self.marked(scalar) || (isMark && marks > 2) || baseless || k >= Self.maxClusterScalars {
                    marker(scalar)
                } else if escaped, scalar == "\"" || scalar == "\\" {
                    text.append("\\")
                    text.append(scalar)
                } else {
                    text.append(scalar)
                }
            }
        }
        flush()
        self.runs = runs
    }

    /// At most this many code points to a character drawn as itself.
    public static let maxClusterScalars = 8

    /// The characters always shown as markers: control (Cc, U+0085 included) and format (Cf, the bidirectional controls
    /// among them) characters, line and paragraph separators (Zl, Zp), private-use and unassigned code points (Co, Cn: a
    /// character newer than this system's Unicode data is unassigned to it), any other Default_Ignorable_Code_Point (the
    /// Hangul fillers, the variation selectors, U+FE0F and the joiners among them), and every space separator (Zs) but
    /// U+0020. Also (chosen; not in the spec) the brackets markers are drawn with, U+27E8 and U+27E9, and their look-alikes,
    /// so that no text can spell a marker, however it is styled.
    /// Always markers (chosen; not in the spec). ⟨ ⟩ and the angle brackets that look like them: 〈 〉 (U+2329, U+232A), 〈 〉 (U+3008, U+3009), ❬ ❭ (U+276C, U+276D),
    /// ‹ › (U+2039, U+203A), ❮ ❯ (U+276E, U+276F), ⟪ ⟫ (U+27EA, U+27EB), ＜ ＞ (U+FF1C, U+FF1E), ⧼ ⧽ (U+29FC, U+29FD),
    /// ⦑ ⦒ (U+2991, U+2992), ❰ ❱ (U+2770, U+2771), 《 》 (U+300A, U+300B), ﹤ ﹥ (U+FE64, U+FE65), ˂ ˃ (U+02C2, U+02C3),
    /// ᐸ ᐳ (U+1438, U+1433), and the blank glyphs that are not default-ignorable: U+2800 BRAILLE PATTERN BLANK and U+FFFC
    /// OBJECT REPLACEMENT CHARACTER.
    static let markerBrackets: Set<UInt32> = [
        0x27E8, 0x27E9, 0x2329, 0x232A, 0x3008, 0x3009, 0x276C, 0x276D, 0x2039, 0x203A, 0x276E, 0x276F, 0x27EA, 0x27EB,
        0xFF1C, 0xFF1E, 0x29FC, 0x29FD, 0x2991, 0x2992, 0x2770, 0x2771, 0x300A, 0x300B, 0xFE64, 0xFE65, 0x02C2, 0x02C3,
        0x1438, 0x1433, 0x2800, 0xFFFC,
        // The continuation mark the screen draws (↳) and its look-alikes: ↪ ⤷ ↴ ⮡ └ ╰ ⤶ ↲.
        0x21B3, 0x21AA, 0x2937, 0x21B4, 0x2BA1, 0x2514, 0x2570, 0x2936, 0x21B2,
        // The Prepend characters that are not format characters (those are marked already): each clusters with what
        // follows it, a `\` the app inserts or the app's own quotation mark (Unicode 15 Grapheme_Cluster_Break=Prepend).
        0x0D4E, 0x111C2, 0x111C3, 0x1193F, 0x11941, 0x11A3A, 0x11A84, 0x11A85, 0x11A86, 0x11A87, 0x11A88, 0x11A89,
        0x11D46, 0x11F02,
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
