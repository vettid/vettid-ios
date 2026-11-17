#if os(iOS)
import SwiftUI
import VettIDApprovals

/// What VoiceOver reads on this screen, and what a braille display shows. The separation does not rest on pitch: the
/// document's text is read between quotation marks (the ones drawn, or spoken ones where none is drawn), with its own
/// `"` and `\` escaped, so no text can close them; those marks, the markers and the app's punctuation are spoken as
/// punctuation; the document's text has a pitch of its own as well, a cue only.
enum Spoken: Equatable {
    /// The app's words, at the usual pitch.
    case app(String)
    /// The app's punctuation and markers, always spoken (and shown in braille) as punctuation.
    case symbol(String)
    /// The document's own text.
    case content(String)

    /// The pitch of the document's text. UIKit's scale is 0 to 2 with 1 the usual pitch, SwiftUI's -1 to 1 with 0; 0.5
    /// differs from the usual on either.
    static let contentPitch = 0.5

    /// What a piece reads: a raw line's level first; a value's text with its `"` and `\` escaped (a raw view's already are).
    static func of(_ p: DocPiece, raw: Bool) -> [Spoken] {
        var out: [Spoken] = p.level.map { [.app(ApprovalsStrings.docLevelSpoken($0) + ", ")] } ?? []
        for t in p.tokens {
            switch t {
            case .punct(let s): out.append(.symbol(s))
            case .spokenQuote: out.append(.symbol("\""))
            case .content(let s): out.append(.content(raw ? s : escaped(s)))
            case .literal(let s): out.append(.app(s))
            case .marker(let v): out.append(.symbol(ShownText.marker(v)))
            case .lineBreak: out.append(.app("\n"))
            case .indent, .open, .close: break
            }
        }
        return out
    }

    /// Code point by code point, as ``ShownText`` escapes the raw view: a `"` or `\\` that carries a mark is escaped too.
    static func escaped(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar == "\"" || scalar == "\\" { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
    }

    static func plain(_ pieces: [Spoken]) -> String {
        pieces.map { p in
            switch p {
            case .app(let s), .symbol(let s), .content(let s): s
            }
        }.joined()
    }

    /// One attributed text: never a chain of concatenated texts, whose depth grows with the document.
    static func attributed(_ pieces: [Spoken]) -> AttributedString {
        var out = AttributedString()
        for p in pieces {
            switch p {
            case .app(let s): out += AttributedString(s)
            case .symbol(let s):
                var a = AttributedString(s)
                a.accessibilitySpeechIncludesPunctuation = true
                out += a
            case .content(let s):
                var a = AttributedString(s)
                a.accessibilitySpeechAdjustedPitch = contentPitch
                out += a
            }
        }
        return out
    }

    static func text(_ pieces: [Spoken]) -> Text { Text(attributed(pieces)) }
}
#endif
