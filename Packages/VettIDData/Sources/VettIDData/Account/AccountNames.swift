import Foundation

/// The account's first and last name (VAULT-MESSAGING §10.8, §11.13): the names the member gave VettID at registration
/// or later changed from this app (`account.name.set`), which every connection sees in the shared profile's core.
/// VettID does not verify them: apps may call them the name on the VettID account, never verified, legal or checked.
/// Mirrors vettid-android `AccountNames`.
public enum AccountNames {
    /// The registration rule's length (MEMBER-API `/api/public/request`), in UTF-16 code units.
    public static let maxRequested = 40

    /// The most a stored or received name may take, in UTF-8 bytes (§10.8, §11.13).
    public static let maxBytes = 160

    private static let rule = #"[\p{L}\p{M}][\p{L}\p{M} '’.\-]*"#

    /// Why a requested name fails the registration rule, or ``ok``.
    public enum Check: Equatable, Sendable { case ok, empty, tooLong, invalid }

    /// A name the member typed, trimmed of leading and trailing spaces (U+0020 only: other white space at either end
    /// fails the pattern), as `account.name.set` sends it; nil when it fails ``check(_:)``.
    public static func normalize(_ s: String) -> String? { check(s) == .ok ? trimSpaces(s) : nil }

    /// The registration rule (§10.8): after trimming U+0020, `^[\p{L}\p{M}][\p{L}\p{M} '’.-]*$`, at most 40 UTF-16 code
    /// units. Checked before the PIN and the password are asked for.
    public static func check(_ s: String) -> Check {
        let t = trimSpaces(s)
        if t.isEmpty { return .empty }
        if t.utf16.count > maxRequested { return .tooLong }
        guard let re = try? Regex(rule), t.wholeMatch(of: re.matchingSemantics(.unicodeScalar)) != nil else { return .invalid }
        return .ok
    }

    /// A name as the snapshot and the shared profile's core carry it (§10.8 "Receiving", §11.13): a string of 1–160
    /// UTF-8 bytes without control characters (C0, C1, U+2028, U+2029) and without lone surrogates (which a Swift
    /// string cannot hold: decoding replaced them).
    public static func isValidCore(_ s: String?) -> Bool {
        guard let s, !s.isEmpty, s.utf8.count <= maxBytes else { return false }
        return !s.unicodeScalars.contains { isControl($0.value) }
    }

    /// C0, C1, U+2028 and U+2029 (§10.8 "Receiving").
    private static func isControl(_ cp: UInt32) -> Bool { cp < 0x20 || (0x80...0x9F).contains(cp) || cp == 0x2028 || cp == 0x2029 }

    /// "First Last" (§10.8: first name, one space, last name); nil unless both are valid core names.
    public static func full(_ first: String?, _ last: String?) -> String? {
        guard isValidCore(first), isValidCore(last), let first, let last else { return nil }
        return "\(first) \(last)"
    }

    /// A received name made safe to sit in a sentence, next to fixed wording, or alone (§10.8): every control and format
    /// character removed (a PDI or an RLO in it cannot close the isolation or reverse the words around it) except ZWJ and
    /// ZWNJ, which emoji sequences and Persian or Indic shaping need; line breaks (U+2028, U+2029 and U+0085 included) and
    /// tabs as spaces; trimmed; then in bidirectional isolation (FSI … PDI). Nil when nothing is left. The one cleaning
    /// step for every name another member controls. Mirrors vettid-android `AccountNames.isolateOrNull`.
    public static func isolateOrNull(_ s: String?) -> String? { cleaned(s).map(wrapIsolated) }

    /// ``isolateOrNull(_:)`` for a name that must be shown: an empty result is an empty isolate, never the raw text.
    public static func isolate(_ s: String) -> String { isolateOrNull(s) ?? wrapIsolated("") }

    /// ``isolateOrNull(_:)`` without the isolation (an initial, a search key); an isolate it is given is stripped too.
    public static func cleaned(_ s: String?) -> String? {
        guard let s else { return nil }
        var out = String.UnicodeScalarView()
        var afterCR = false
        for u in s.unicodeScalars {
            defer { afterCR = u == "\r" }
            if u == "\n", afterCR { continue } // CRLF: one break
            if isBreak(u.value) {
                out.append(" ")
            } else if !isInvisible(u) {
                out.append(u)
            }
        }
        // All Unicode white space, as Kotlin's `trim()` (NBSP, U+2003, U+3000 included).
        let t = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// [s], already cleaned by the caller, in isolation as it is (a note's line breaks stay).
    public static func wrapIsolated(_ s: String) -> String { "\u{2068}\(s)\u{2069}" }

    private static func isBreak(_ cp: UInt32) -> Bool {
        cp == 0x09 || cp == 0x0A || cp == 0x0D || cp == 0x85 || cp == 0x2028 || cp == 0x2029
    }

    /// Control and format characters (bidi controls, zero-width characters, BOM, tags), except ZWJ and ZWNJ.
    private static func isInvisible(_ u: Unicode.Scalar) -> Bool {
        if u.value == 0x200C || u.value == 0x200D { return false }
        switch u.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    private static func trimSpaces(_ s: String) -> String {
        var scalars = Substring.UnicodeScalarView(s.unicodeScalars)
        while scalars.first == " " { scalars.removeFirst() }
        while scalars.last == " " { scalars.removeLast() }
        return String(scalars)
    }
}
