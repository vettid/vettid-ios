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
    /// kept, a third and later in a row are markers; elsewhere every LF is a marker.
    public init(_ s: String, lineBreaks: Bool = false) {
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
            if isBreak, lineBreaks, breaks <= 2 {
                flush()
                runs.append(.lineBreak)
            } else if isBreak || Self.marked(scalar) || (isMark && marks > 2) {
                flush()
                runs.append(.marker(scalar.value))
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
    /// U+0020.
    static func marked(_ scalar: Unicode.Scalar) -> Bool {
        let p = scalar.properties
        switch p.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: return true
        case .spaceSeparator: return scalar != " "
        default: return p.isDefaultIgnorableCodePoint
        }
    }
}
