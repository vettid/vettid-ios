import Foundation

/// An `item.use`'s data as the member sees it (ANDROID-PLAN 0.1.116 AA5, decision 18): the text when the bytes are printable
/// UTF-8, else hex. The data is the agent's own choice, not a secret of the member's. Mirrors vettid-android `DataView`.
public enum DataView: Equatable, Sendable {
    case text(String)
    case hex(String)

    /// The most combining marks in a row.
    public static let maxMarks = 2
    /// The most blank characters in a row (tabs, spaces of any width).
    public static let maxBlanks = 8
    /// The most lines shown as text.
    public static let maxLines = 8
    /// The most bytes shown at all: `item.use`'s own bound on `data` (VAULT-MESSAGING §10.11, ``HeldApprovals/maxData``).
    public static let maxBytes = HeldApprovals.maxData

    private static let brailleBlank: UInt32 = 0x2800

    /// Printable: strictly valid UTF-8, and nothing that could hide, reorder or fake what the member reads. Hex when it has: a
    /// control character other than a line feed or tab; a format character (the bidirectional overrides and isolates, zero
    /// width characters); a Default_Ignorable code point (soft hyphen, the Hangul fillers, variation selectors, the combining
    /// grapheme joiner, tag characters); an unassigned, private-use or surrogate code point; the braille blank U+2800; a run of
    /// more than ``maxBlanks`` blank characters; a line or paragraph separator; a run of more than ``maxMarks`` combining marks
    /// on one base; more than ``maxLines`` lines. Nil for more than ``maxBytes`` bytes: never shown, as no `item.use` carries
    /// them, so the request is not approved.
    public static func of(_ data: [UInt8]) -> DataView? {
        guard data.count <= maxBytes else { return nil }
        // Strictly valid UTF-8, and nothing dropped on the way (a byte order mark): the round trip is the check.
        guard let text = String(bytes: data, encoding: .utf8), text.utf8.elementsEqual(data), printable(text) else {
            return .hex(hex(data))
        }
        return .text(text)
    }

    /// Lower-case hex, two digits a byte, a space between bytes.
    public static func hex(_ data: [UInt8]) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func printable(_ s: String) -> Bool {
        var lines = 1
        var marks = 0
        var blanks = 0
        for c in s.unicodeScalars {
            if c.value == 0x0A {
                lines += 1
                if lines > maxLines { return false }
            }
            marks = isMark(c) ? marks + 1 : 0
            blanks = blank(c) ? blanks + 1 : 0
            if marks > maxMarks || blanks > maxBlanks || !shown(c) { return false }
        }
        return true
    }

    /// A character that shows as blank: a tab, or a space of any width (Zs).
    private static func blank(_ c: Unicode.Scalar) -> Bool { c.value == 0x09 || c.properties.generalCategory == .spaceSeparator }

    private static func isMark(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark: true
        default: false
        }
    }

    private static func shown(_ c: Unicode.Scalar) -> Bool {
        if c.value == 0x0A || c.value == 0x09 { return true }
        if c.properties.isDefaultIgnorableCodePoint || c.value == brailleBlank { return false }
        switch c.properties.generalCategory {
        case .control, .format, .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator: return false
        default: return true
        }
    }
}
