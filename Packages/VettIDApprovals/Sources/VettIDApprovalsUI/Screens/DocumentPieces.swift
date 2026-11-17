#if os(iOS)
import Foundation

/// A document's texts in bounded pieces, each drawn as a text of its own: a single text of tens of kilobytes, as tall as
/// hundreds of thousands of points at the largest text size, is drawn blank on an iPhone (past what one layer holds),
/// and the screen would then count as seen what was never drawn. A piece ends after a white space where there is one,
/// else at a change of style (never inside a marker), else at the bound.
enum DocumentPieces {
    /// At most this many characters to a piece: a few thousand points tall at the largest text size.
    static let maxCharacters = 200

    /// [text] in pieces of at most [max] characters (a kept line break that ends a piece is the break between pieces).
    static func pieces(_ text: AttributedString, max: Int = maxCharacters) -> [AttributedString] {
        var out: [AttributedString] = []
        var rest = text[text.startIndex..<text.endIndex]
        // Each pass looks at the next [max] characters only: the whole is never counted again (a 65 KB line).
        while let window = rest.characters.index(rest.startIndex, offsetBy: max, limitedBy: rest.endIndex),
              window < rest.endIndex {
            let cut = cutIndex(in: rest, before: window)
            var piece = AttributedString(rest[rest.startIndex..<cut])
            if piece.characters.last == "\n" {
                piece.characters.removeLast()
            }
            out.append(piece)
            rest = rest[cut...]
        }
        if !rest.characters.isEmpty || out.isEmpty { out.append(AttributedString(rest)) }
        return out
    }

    /// Where a piece of [s] ends, no later than [limit]: after its last white space or line break, else at its last change
    /// of style, else at [limit].
    private static func cutIndex(in s: AttributedSubstring, before limit: AttributedString.Index) -> AttributedString.Index {
        var i = limit
        while i > s.startIndex {
            let prev = s.characters.index(before: i)
            if s.characters[prev].isWhitespace { return i }
            i = prev
        }
        var lastBoundary: AttributedString.Index?
        for run in s[s.startIndex..<limit].runs where run.range.lowerBound > s.startIndex {
            lastBoundary = run.range.lowerBound
        }
        return lastBoundary ?? limit
    }

    /// A raw view's line in pieces: each piece after the first starts again left-to-right, and an isolate a cut falls in
    /// is closed at the end of its piece and opened again at the start of the next, so a string's direction still
    /// reaches nothing outside it.
    static func rawPieces(_ line: AttributedString, max: Int = maxCharacters) -> [AttributedString] {
        let parts = pieces(line, max: max)
        guard parts.count > 1 else { return parts }
        var out: [AttributedString] = []
        var open: [AttributeContainer] = []
        for (n, part) in parts.enumerated() {
            var piece = AttributedString()
            if n > 0 {
                piece += AttributedString(RawDocumentView.lrm)
                for attrs in open { piece += AttributedString(RawDocumentView.fsi, attributes: attrs) }
            }
            for run in part.runs {
                for c in part[run.range].characters {
                    if String(c) == RawDocumentView.fsi { open.append(run.attributes) }
                    if String(c) == RawDocumentView.pdi, !open.isEmpty { open.removeLast() }
                }
            }
            piece += part
            for attrs in open.reversed() { piece += AttributedString(RawDocumentView.pdi, attributes: attrs) }
            out.append(piece)
        }
        return out
    }
}
#endif
