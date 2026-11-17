import Foundation

/// One row of a document on its screen (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"), as tokens drawn and spoken
/// the same way: the app's own punctuation, the document's text, markers. A document is cut into pieces of at most
/// ``ShownText/pieceCharacters`` characters, each drawn as a row of its own (a single text of tens of kilobytes is drawn
/// blank on an iPhone, and drawn whole is more than an app may hold); a cut never falls inside a marker, an escape or a
/// character, and each piece carries its own frame: a piece after the first starts with ↳, drawn and spoken, and its
/// text is read between quotation marks, so no piece can be read as a line of the app's or as a value of its own.
public struct DocPiece: Equatable, Sendable {
    public enum Token: Equatable, Sendable {
        /// The app's punctuation (quotation marks, `: `, `,`, brackets, ↳): drawn, and always spoken as punctuation.
        case punct(String)
        /// A raw view's indent: this many levels, drawn as spaces, not spoken.
        case indent(Int)
        /// A key's or string's isolate (U+2068 … U+2069): drawn, not spoken.
        case open, close
        /// A quotation mark spoken around the document's text where none is drawn (a value, a piece after a cut).
        case spokenQuote
        /// The document's text, as drawn (a raw view's with its `"` and `\` escaped).
        case content(String)
        /// A number, `true`, `false` or `null` of the raw view: drawn and spoken as it is, never between quotation marks.
        case literal(String)
        case marker(UInt32)
        /// A kept line break (Motion, Quorum's text).
        case lineBreak
    }

    public var tokens: [Token]
    /// A raw view's line's level (§10.4: the document object is level 1), on its first piece only.
    public var level: Int?
    /// A piece after the first of its value or line.
    public var continuation: Bool

    /// The continuation mark, drawn and spoken at the start of a piece after a cut.
    public static let continued = "↳ "

    /// How many characters the piece draws.
    public var length: Int { tokens.reduce(0) { $0 + Self.length($1) } }

    static func length(_ t: Token) -> Int {
        switch t {
        case .punct(let s), .content(let s), .literal(let s): s.count
        case .indent(let n): 2 * n
        case .marker(let v): ShownText.marker(v).count
        case .lineBreak: 1
        case .open, .close, .spokenQuote: 0
        }
    }

    // MARK: - A form's value

    /// A value under a form's label, in pieces: each read between quotation marks, a piece after the first marked ↳.
    public static func value(_ t: ShownText, max: Int = ShownText.pieceCharacters) -> [DocPiece] {
        t.pieces(max: max - continued.count).enumerated().map { i, piece in
            var tokens: [Token] = i > 0 ? [.punct(continued)] : []
            tokens.append(.spokenQuote)
            for run in piece.runs {
                switch run {
                case .text(let s): tokens.append(.content(s))
                case .marker(let v): tokens.append(.marker(v))
                case .lineBreak: tokens.append(.lineBreak)
                }
            }
            tokens.append(.spokenQuote)
            return DocPiece(tokens: tokens, level: nil, continuation: i > 0)
        }
    }

    // MARK: - The raw view

    /// A raw view's line as tokens: its indent, its key and value, brackets and comma.
    public static func tokens(_ line: DocumentPresentation.RawLine) -> [Token] {
        var t: [Token] = [.indent(line.depth)]
        if let key = line.key { t += [.punct("\"")] + isolated(key) + [.punct("\": ")] }
        switch line.value {
        case .string(let s): t += [.punct("\"")] + isolated(s) + [.punct("\"")]
        case .number(let n): t.append(.literal(n))
        case .bool(let b): t.append(.literal(b ? "true" : "false"))
        case .null: t.append(.literal("null"))
        case .open(let c): t.append(.punct(c == .object ? "{" : "["))
        case .close(let c): t.append(.punct(c == .object ? "}" : "]"))
        case .empty(let c): t.append(.punct(c == .object ? "{}" : "[]"))
        }
        if line.comma { t.append(.punct(",")) }
        return t
    }

    private static func isolated(_ s: ShownText) -> [Token] {
        var t: [Token] = [.open]
        for run in s.runs {
            switch run {
            case .text(let x): t.append(.content(x))
            case .marker(let v): t.append(.marker(v))
            case .lineBreak: t.append(.marker(0x0A))
            }
        }
        t.append(.close)
        return t
    }

    /// A raw view's line in pieces of at most [max] characters. A piece cut inside a key or string closes its isolate and
    /// is read with a closing quotation mark; the next starts with ↳, reopens the isolate and is read from an opening one.
    public static func raw(_ line: DocumentPresentation.RawLine, max: Int = ShownText.pieceCharacters) -> [DocPiece] {
        var cutter = Cutter(level: line.depth + 1, max: max)
        for token in tokens(line) { cutter.add(token) }
        return cutter.finish()
    }

    /// Cuts a line's tokens into pieces.
    private struct Cutter {
        let level: Int
        let max: Int
        var pieces: [DocPiece] = []
        var cur: [Token] = []
        var n = 0
        var inIsolate = false

        init(level: Int, max: Int) {
            self.level = level
            self.max = max
        }

        /// Nothing but the continuation mark (or nothing) in the piece yet.
        var fresh: Bool { n <= (pieces.isEmpty ? 0 : DocPiece.continued.count) }

        mutating func close() {
            if inIsolate { cur += [.close, .spokenQuote] }
            pieces.append(DocPiece(tokens: cur, level: pieces.isEmpty ? level : nil, continuation: !pieces.isEmpty))
            cur = [.punct(DocPiece.continued)] + (inIsolate ? [.spokenQuote, .open] : [])
            n = DocPiece.continued.count
        }

        mutating func add(_ token: Token) {
            switch token {
            case .open: inIsolate = true
            case .close: inIsolate = false
            default: break
            }
            guard case .content(let s) = token else {
                let len = DocPiece.length(token)
                if len > 0, n + len > max, !fresh { close() }
                cur.append(token)
                n += len
                return
            }
            var rest = Substring(s)
            while !rest.isEmpty {
                guard let limit = rest.index(rest.startIndex, offsetBy: max - n, limitedBy: rest.endIndex),
                      limit < rest.endIndex
                else {
                    n += rest.count
                    cur.append(.content(String(rest)))
                    return
                }
                var cut = Self.cut(rest, before: limit)
                if cut == rest.startIndex {
                    guard fresh else {
                        close()
                        continue
                    }
                    // Nothing fits before the bound in a piece of its own: cut at the bound, an escape kept whole.
                    cut = Self.insideEscape(rest, at: limit) ? rest.index(after: limit) : limit
                }
                cur.append(.content(String(rest[..<cut])))
                rest = rest[cut...]
                close()
            }
        }

        /// Where to cut [s] no later than [limit]: after its last white space, else at [limit]; never between a `\` and
        /// the character it escapes (the cut moves back by one).
        static func cut(_ s: Substring, before limit: Substring.Index) -> Substring.Index {
            var c = limit
            if let ws = s[..<limit].lastIndex(where: \.isWhitespace) { c = s.index(after: ws) }
            if insideEscape(s, at: c) { c = s.index(before: c) }
            return c
        }

        /// Whether [i] falls between a `\` and the character it escapes: an odd run of backslashes ends just before it (in
        /// a raw view's text every backslash starts an escape).
        static func insideEscape(_ s: Substring, at i: Substring.Index) -> Bool {
            var slashes = 0
            var j = i
            while j > s.startIndex {
                let prev = s.index(before: j)
                guard s[prev] == "\\" else { break }
                slashes += 1
                j = prev
            }
            return slashes % 2 == 1
        }

        mutating func finish() -> [DocPiece] {
            if !cur.isEmpty, cur != [.punct(DocPiece.continued)] || pieces.isEmpty {
                pieces.append(DocPiece(tokens: cur, level: pieces.isEmpty ? level : nil, continuation: !pieces.isEmpty))
            }
            return pieces
        }
    }
}
