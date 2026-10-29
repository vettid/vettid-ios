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

    /// A received name made safe to sit in a sentence, next to fixed wording, or alone (VAULT-MESSAGING 0.76.0 §10.8
    /// "Showing received text"): ``cleaned(_:)``, then in bidirectional isolation (FSI … PDI). Nil when it is empty
    /// (step 4). The one cleaning step for every string another party controls. Mirrors vettid-android
    /// `AccountNames.isolateOrNull`.
    public static func isolateOrNull(_ s: String?) -> String? { cleaned(s).map(wrapIsolated) }

    /// ``isolateOrNull(_:)`` for a name that must be shown: an empty result is an empty isolate, never the raw text.
    public static func isolate(_ s: String) -> String { isolateOrNull(s) ?? wrapIsolated("") }

    /// ``isolateOrNull(_:)`` without the isolation (an initial, a search key): steps 1-4 as one line (every break and tab a
    /// space; Cc and Cf removed but ZWJ and ZWNJ; White_Space trimmed). Nil when nothing is left once
    /// Default_Ignorable_Code_Point and White_Space code points are set aside. Also strips an isolate it is given.
    public static func cleaned(_ s: String?) -> String? {
        s.map { scrub($0, keepLines: false, keepMarks: false, wholeText: false) }.flatMap { isEmptyText($0) ? nil : $0 }
    }

    /// ``cleaned(_:)``, cut at [max] code points (never inside a grapheme cluster) and cleaned again, so that the cut cannot
    /// leave trailing white space or an empty-looking name. Nil when empty. For a received file name (§10.5.1).
    public static func cleanedCapped(_ s: String?, max: Int) -> String? {
        guard let c = cleaned(s) else { return nil }
        guard c.unicodeScalars.count > max else { return c }
        var kept = ""
        var n = 0
        for ch in c {
            n += ch.unicodeScalars.count
            if n > max { break }
            kept.append(ch)
        }
        return cleaned(kept)
    }

    /// Steps 1-3 for text whose lines are kept (a context, a note): every break one LF, each line trimmed, no empty line at
    /// either end. Nil when empty (step 4). Not isolated: see ``isolateLines(_:)``.
    public static func cleanedLines(_ s: String?) -> String? {
        s.map { scrub($0, keepLines: true, keepMarks: false, wholeText: false) }.flatMap { isEmptyText($0) ? nil : $0 }
    }

    /// A message's full text for its own bubble: as ``cleanedLines(_:)`` but LRM, RLM and ALM are kept and only the ends of
    /// the whole text are trimmed (a line's indentation stays). Not isolated: see ``isolateLines(_:)``. Empty string when
    /// nothing shows.
    public static func cleanedMessage(_ s: String?) -> String {
        guard let s else { return "" }
        let t = scrub(s, keepLines: false, keepMarks: true, wholeText: true)
        return isEmptyText(t) ? "" : t
    }

    /// [s] (already cleaned) with every line in its own isolate: an isolate ends at a line break (§10.8 step 5).
    public static func isolateLines(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { wrapIsolated(String($0)) }.joined(separator: "\n")
    }

    /// True when [s] shows nothing: only Default_Ignorable_Code_Point and White_Space code points remain (step 4).
    public static func isEmptyText(_ s: String) -> Bool {
        !s.unicodeScalars.contains { !$0.properties.isWhitespace && !$0.properties.isDefaultIgnorableCodePoint }
    }

    /// The first line of [s] (steps 1-3, lines kept) that is not empty by step 4, isolated; nil when there is none (step 6:
    /// a one-line summary of a multi-line text).
    public static func firstLineIsolated(_ s: String?) -> String? {
        guard let s else { return nil }
        return scrub(s, keepLines: true, keepMarks: false, wholeText: false)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !isEmptyText(String($0)) }
            .map { wrapIsolated(String($0)) }
    }

    /// [s], already cleaned by the caller, in isolation as it is.
    public static func wrapIsolated(_ s: String) -> String { "\u{2068}\(s)\u{2069}" }

    /// Steps 1-3 of §10.8 (a Swift string cannot hold a lone surrogate: decoding already replaced it with U+FFFD, which is
    /// kept). The breaks are read in the text as received: CR immediately followed by LF is one break, CR, ZWSP, LF is two.
    private static func scrub(_ s: String, keepLines: Bool, keepMarks: Bool, wholeText: Bool) -> String {
        let brk: Unicode.Scalar = keepLines || wholeText ? "\n" : " "
        var out = String.UnicodeScalarView()
        var afterCR = false
        for u in s.unicodeScalars {
            defer { afterCR = u == "\r" }
            switch u.value {
            case 0x0A where afterCR: continue // CRLF: one break
            case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: out.append(brk)
            case 0x09: out.append(" ")
            case 0x200C, 0x200D: out.append(u)
            default: if !isInvisible(u) || (keepMarks && isDirectionalMark(u)) { out.append(u) }
            }
        }
        return keepLines ? String(trimLines(out)) : String(trimWhiteSpace(out[...]))
    }

    /// Each line trimmed, and no empty line at either end.
    private static func trimLines(_ v: String.UnicodeScalarView) -> String.UnicodeScalarView {
        var lines = v.split(separator: "\n", omittingEmptySubsequences: false).map { trimWhiteSpace($0) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var joined = String.UnicodeScalarView()
        for (i, l) in lines.enumerated() {
            if i > 0 { joined.append("\n") }
            joined.append(contentsOf: l)
        }
        return joined
    }

    /// LRM, RLM and ALM: they set no direction for the text around them (kept in a message's bubble).
    private static func isDirectionalMark(_ u: Unicode.Scalar) -> Bool { u.value == 0x061C || u.value == 0x200E || u.value == 0x200F }

    /// The Unicode White_Space property, at both ends.
    private static func trimWhiteSpace(_ v: Substring.UnicodeScalarView) -> Substring.UnicodeScalarView {
        var v = v
        while let f = v.first, f.properties.isWhitespace { v.removeFirst() }
        while let l = v.last, l.properties.isWhitespace { v.removeLast() }
        return v
    }

    /// Control and format characters (bidi controls, zero-width characters, BOM, tags); the callers keep ZWJ and ZWNJ.
    private static func isInvisible(_ u: Unicode.Scalar) -> Bool {
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
