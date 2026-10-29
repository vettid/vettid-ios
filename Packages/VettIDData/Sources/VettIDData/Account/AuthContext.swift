import Foundation

/// A challenge's `context` is the connection's own words (VAULT-MESSAGING §10.4, shown in full): text that cannot reorder or
/// hide anything. Unlike a name it keeps its line breaks. Mirrors vettid-android `AuthContext`.
public enum AuthContext {
    /// [s] with control and format characters removed (bidi controls, zero-width ones; ZWJ and ZWNJ stay), tabs as spaces, and
    /// line breaks (CR, CRLF as one, U+2028, U+2029, U+0085) kept as "\n", so that a note's lines stay visible.
    public static func plain(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var afterCR = false
        for u in s.unicodeScalars {
            defer { afterCR = u == "\r" }
            switch u.value {
            case 0x0A: if !afterCR { out.append("\n") }
            case 0x0D, 0x85, 0x2028, 0x2029: out.append("\n")
            case 0x09: out.append(" ")
            case 0x200C, 0x200D: out.append(u)
            default:
                switch u.properties.generalCategory {
                case .control, .format: break
                default: out.append(u)
                }
            }
        }
        return String(out)
    }

    /// ``plain(_:)`` in bidirectional isolation (FSI … PDI, §10.8), for next to other text; nil when nothing is left.
    public static func isolated(_ s: String) -> String? {
        let t = plain(s)
        return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : AccountNames.wrapIsolated(t)
    }
}
