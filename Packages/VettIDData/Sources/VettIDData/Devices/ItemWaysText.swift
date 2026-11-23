import Foundation

// What the pages of AA7 (ANDROID-PLAN 0.1.137) show of a string, a fingerprint and a program, and of the vault's refusal. Pure and
// memory only; no text of a screen is here (those are `ItemWaysStrings`). Mirrors vettid-android `ShownString`, `Fingerprints`,
// `ProgramAdvice`, `shownWays` and `VaultReason`.

/// A piece of a string as ANDROID-PLAN 0.1.137 AA8 "How a string is shown" draws it: plain printable ASCII ([text] with `plain`),
/// other characters highlighted ([text] without), an escaped code point ([escape]) or a marked space ([space]).
public enum ShownPiece: Equatable, Sendable {
    case text(String, plain: Bool)
    case escape(UInt32)
    case space

    /// `U+202E`: at least four hex digits, upper case.
    public static func label(_ codePoint: UInt32) -> String {
        let hex = String(codePoint, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}

/// AA8 "How a string is shown": what is escaped, what is marked and what is highlighted.
public enum ShownString {
    private static let space: UInt32 = 0x20
    private static let tilde: UInt32 = 0x7E
    private static let brailleBlank: UInt32 = 0x2800

    /// Escaped on its own: Cc, Cf, Zl, Zp, Co, Cs, Cn; every White_Space code point but U+0020; every
    /// Default_Ignorable_Code_Point; U+2800 BRAILLE PATTERN BLANK.
    public static func escaped(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: return true
        default: break
        }
        return (c.value != space && c.properties.isWhitespace) || c.properties.isDefaultIgnorableCodePoint || c.value == brailleBlank
    }

    private static func combining(_ c: Unicode.Scalar) -> Bool {
        c.properties.generalCategory == .nonspacingMark || c.properties.generalCategory == .enclosingMark
    }

    /// [s] by the string rule as plain text, for a string inside a sentence (a dialog's text, a line of advice): isolated and forced
    /// left to right (LRI LRO … PDF PDI), each space as `·`, and every code point outside printable ASCII as `⟨U+XXXX⟩` (the
    /// approval documents' markers), since nothing here is highlighted: so a look-alike, or a literal `·`, `⟨` or `⟩`, cannot pass
    /// for something else. An empty string is [empty] between markers. The box (``pieces(_:)``) is the full form.
    public static func inline(_ s: String, empty: String) -> String {
        var out = "\u{2066}\u{202D}"
        if s.isEmpty { out += "⟨" + empty + "⟩" }
        for p in pieces(s) {
            switch p {
            case .text(let t, let plain):
                if plain { out += t } else { for c in t.unicodeScalars { out += marker(c.value) } }
            case .escape(let cp): out += marker(cp)
            case .space: out += "·"
            }
        }
        return out + "\u{202C}\u{2069}"
    }

    private static func marker(_ cp: UInt32) -> String { "⟨" + ShownPiece.label(cp) + "⟩" }

    /// [s] as pieces, in order. A combining mark at the start, right after a `/` or `\`, an escape or a marked space is escaped
    /// too, so it cannot join the box's edge, a separator, an escape or a space mark.
    public static func pieces(_ s: String) -> [ShownPiece] {
        var out: [ShownPiece] = []
        var run = String.UnicodeScalarView()
        var runPlain = true
        func flush() {
            if !run.isEmpty { out.append(.text(String(run), plain: runPlain)) }
            run = String.UnicodeScalarView()
        }
        var prev: UInt32?
        var prevBreaks = true // the start counts as an edge
        for c in s.unicodeScalars {
            let edge = prevBreaks || prev == 0x2F || prev == 0x5C
            if escaped(c) || (combining(c) && edge) {
                flush()
                out.append(.escape(c.value))
                prevBreaks = true
            } else if c.value == space {
                flush()
                out.append(.space)
                prevBreaks = true
            } else {
                let plain = (space...tilde).contains(c.value)
                if !run.isEmpty && plain != runPlain { flush() }
                runPlain = plain
                run.append(c)
                prevBreaks = false
            }
            prev = c.value
        }
        flush()
        return out
    }

    /// "Some characters here may look like others.": a character outside printable ASCII is shown, not escaped.
    public static func lookalike(_ pieces: [ShownPiece]) -> Bool {
        pieces.contains { if case .text(_, let plain) = $0 { !plain } else { false } }
    }
}

/// A recorded fingerprint, as AA7 and AA8 show it.
public enum Fingerprints {
    private static let shortDigits = 16
    private static let group = 4

    /// The first 16 hex digits in groups of four: "1a2b 3c4d 5e6f 7a8b".
    public static func short(_ sha256: String) -> String { grouped(String(sha256.prefix(shortDigits))) }

    /// All 64 digits in groups of four.
    public static func full(_ sha256: String) -> String { grouped(sha256) }

    private static func grouped(_ s: String) -> String {
        let chars = Array(s)
        return stride(from: 0, to: chars.count, by: group).map { String(chars[$0..<min($0 + group, chars.count)]) }.joined(separator: " ")
    }
}

/// Advice on a listed program (AA7 "Run settings"; AA8 "A batch file's fingerprint").
public enum ProgramAdvice {
    private static let endings = [".exe", ".com", ".cmd", ".bat", ".ps1"]

    /// vettid/vettid.org#636: programs that can run other commands given in their arguments.
    public static let runsCommandsNames: Set<String> = [
        "git", "rsync", "tar", "sed", "npm", "yarn", "pnpm", "uv", "dotnet", "make", "find", "vim", "nvim", "vi", "ex", "cargo",
        "go", "gradle", "mvn", "pip", "pip3", "docker", "podman", "kubectl", "terraform", "gh", "scp", "sftp", "less", "ed", "zip",
    ]

    private static func trimmed(_ s: String) -> String {
        var u = Array(s.unicodeScalars)
        while let l = u.last, l == " " || l == "." { u.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: u)
        return String(out)
    }

    private static func lowerLast(_ program: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: ItemWaysRules.simpleLower(ItemWaysRules.lastElement(program)))
        return String(out)
    }

    /// The last path element as VAULT-MESSAGING §10.11's `shell` flag compares it (0.91.1): any case, without any number of final
    /// `.exe`, `.com`, `.cmd`, `.bat` or `.ps1` endings, with trailing dots and spaces trimmed after each.
    public static func nameKey(_ program: String) -> String {
        var k = trimmed(lowerLast(program))
        while let e = endings.first(where: { k.hasSuffix($0) }) { k = trimmed(String(k.dropLast(e.count))) }
        return k
    }

    /// The #636 advice applies: a listed name, or `pip` with digits and dots appended.
    public static func runsCommands(_ program: String) -> Bool {
        let k = nameKey(program)
        guard !k.isEmpty else { return false }
        return runsCommandsNames.contains(k) || versionedPip(k)
    }

    private static func versionedPip(_ k: String) -> Bool {
        guard k.hasPrefix("pip") else { return false }
        let rest = Array(k.utf8.dropFirst(3))
        return rest.first.map { (0x30...0x39).contains($0) } == true && rest.allSatisfy { (0x30...0x39).contains($0) || $0 == 0x2E }
    }

    /// A Windows batch file: the last part ends in `.cmd` or `.bat`, any case, trailing dots and spaces dropped.
    public static func batchFile(_ program: String) -> Bool {
        let last = trimmed(lowerLast(program))
        return last.hasSuffix(".cmd") || last.hasSuffix(".bat")
    }
}

/// The ways an item allows, in the order the agent's page lists them (`use` always first).
public func shownWays(_ ways: [String]) -> [ItemWay] {
    ItemWay.allCases.filter { w in w == .use || ways.contains { same($0, w.wire) } }
}

/// A `leash.item.set` `bad_request`'s `error.message` as ANDROID-PLAN 0.1.138 AA7 "Saving" shows it (VAULT-MESSAGING 0.93.2 §10.11
/// "Why a setting is refused"): the message itself when it is 1 to 200 bytes of printable ASCII (0x20-0x7E), never parsed; else
/// nil, and the page shows the fallback text.
public enum VaultReason {
    private static let maxBytes = 200

    public static func shown(_ message: String?) -> String? {
        guard let m = message, !m.isEmpty, m.utf8.count <= maxBytes, m.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return m
    }
}
