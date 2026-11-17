import Foundation
import Testing
@testable import VettIDApprovals

/// A document's rows (``DocPiece``): bounded pieces, each with its own frame, no cut inside a marker, an escape or a
/// character, and no character of unbounded length.
@Suite struct DocPieceTests {
    func contents(_ pieces: [DocPiece]) -> String {
        pieces.flatMap(\.tokens).compactMap { if case .content(let s) = $0 { s } else { nil } }.joined()
    }

    @Test func aValueIsReadBetweenQuotationMarksAndItsLaterPiecesAreMarked() {
        let words = Array(repeating: "budget", count: 200).joined(separator: " ")
        let pieces = DocPiece.value(ShownText(words))
        #expect(pieces.count > 5 && pieces.allSatisfy { $0.length <= ShownText.pieceCharacters })
        #expect(pieces[0].tokens.first == .spokenQuote && pieces[0].tokens.last == .spokenQuote && !pieces[0].continuation)
        for p in pieces.dropFirst() {
            #expect(p.continuation && p.tokens.prefix(2) == [.punct(DocPiece.continued), .spokenQuote] && p.tokens.last == .spokenQuote)
        }
        #expect(contents(pieces) == words)
        // A value that starts "Yes " is still read as the document's text, between quotation marks.
        let yes = DocPiece.value(ShownText("Yes " + String(repeating: "x", count: 300)))
        #expect(yes[0].tokens.prefix(2) == [.spokenQuote, .content("Yes ")])
    }

    static func line(_ s: String) -> DocumentPresentation.RawLine {
        DocumentPresentation.RawLine(depth: 2, key: ShownText("k", escaped: true), value: .string(ShownText(s, escaped: true)), comma: true)
    }

    @Test func aLongRawLineIsCutWithItsIsolateAndQuotesKeptPerPiece() {
        let words = Array(repeating: "budget", count: 200).joined(separator: " ")
        let pieces = DocPiece.raw(Self.line(words))
        #expect(pieces.count > 5 && pieces.allSatisfy { $0.length <= ShownText.pieceCharacters })
        #expect(pieces[0].level == 3 && pieces.dropFirst().allSatisfy { $0.level == nil && $0.continuation })
        #expect(pieces[0].tokens.suffix(2) == [.close, .spokenQuote], "the first piece closes the string it is cut in")
        for p in pieces.dropFirst().dropLast() {
            #expect(p.tokens.prefix(3) == [.punct(DocPiece.continued), .spokenQuote, .open])
            #expect(p.tokens.suffix(2) == [.close, .spokenQuote])
        }
        #expect(pieces.last?.tokens.suffix(3) == [.close, .punct("\""), .punct(",")])
        #expect(contents(pieces) == "k" + words)
        // Every piece opens as many isolates as it closes.
        for p in pieces {
            #expect(p.tokens.filter { $0 == .open }.count == p.tokens.filter { $0 == .close }.count)
        }
    }

    @Test func noCutFallsInsideAMarkerOrAnEscape() {
        // A string without a white space, of escapes: no piece ends between a backslash and what it escapes.
        let quotes = String(repeating: #"\""#, count: 300)
        for p in DocPiece.raw(Self.line(quotes)) {
            for case .content(let s) in p.tokens {
                let trailing = s.reversed().prefix { $0 == "\\" }.count
                #expect(trailing % 2 == 0, "a piece ends inside an escape")
            }
        }
        // A run of markers: each marker is a token of its own, never cut.
        let markers = DocPiece.raw(Self.line(String(repeating: "\u{202E}", count: 100)))
        #expect(markers.count > 3)
        #expect(markers.flatMap(\.tokens).filter { $0 == .marker(0x202E) }.count == 100)
    }

    @Test func noCharacterIsLongerThanItsBound() {
        // 21,000 Hangul leading jamo are one character; a base with 3,000 marks is another.
        let jamo = String(repeating: "\u{1100}", count: 21_000)
        let marks = "a" + String(repeating: "\u{0301}", count: 3_000)
        for s in [jamo, marks] {
            let t = ShownText(s)
            for case .text(let x) in t.runs {
                #expect(x.allSatisfy { $0.unicodeScalars.count <= ShownText.maxClusterScalars })
            }
            for p in DocPiece.value(t) {
                #expect(p.length <= ShownText.pieceCharacters)
            }
        }
        // Mn and Mc count together in a row: the third mark of either kind is a marker.
        let mixed = ShownText("\u{0915}\u{0903}\u{0941}\u{0903}")
        #expect(mixed.runs == [.text("\u{0915}\u{0903}\u{0941}"), .marker(0x0903)])
    }
}
