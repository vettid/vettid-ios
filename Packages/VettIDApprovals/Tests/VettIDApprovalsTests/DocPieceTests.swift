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
        // A piece cut inside the paragraph ends with ↳ (never a closing quotation mark: it is not the whole of the value);
        // the next starts with ↳ and an opening one; the last ends with the closing one.
        #expect(pieces[0].tokens.first == .spokenQuote && pieces[0].tokens.last == .punct(DocPiece.continues) && !pieces[0].continuation)
        for p in pieces.dropFirst() {
            #expect(p.continuation && p.tokens.prefix(2) == [.punct(DocPiece.continued), .spokenQuote])
        }
        #expect(pieces.dropLast().allSatisfy { $0.tokens.last == .punct(DocPiece.continues) } && pieces.last?.tokens.last == .spokenQuote)
        // A piece after a kept line break starts a paragraph: no ↳.
        let paragraphs = DocPiece.value(ShownText(String(repeating: "a", count: 150) + "\nb", lineBreaks: true))
        #expect(paragraphs.count == 2 && paragraphs[1].tokens.first == .spokenQuote && paragraphs[0].tokens.last == .spokenQuote)
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
        #expect(pieces[0].tokens.suffix(2) == [.close, .punct(DocPiece.continues)], "a cut piece closes its isolate and ends with ↳")
        for p in pieces.dropFirst().dropLast() {
            #expect(p.tokens.prefix(3) == [.punct(DocPiece.continued), .spokenQuote, .open])
            #expect(p.tokens.suffix(2) == [.close, .punct(DocPiece.continues)])
        }
        #expect(pieces.last?.tokens.suffix(3) == [.close, .punct("\""), .punct(",")])
        #expect(contents(pieces) == "k" + words)
        // Every piece opens as many isolates as it closes.
        for p in pieces {
            #expect(p.tokens.filter { $0 == .open }.count == p.tokens.filter { $0 == .close }.count)
        }
    }

    /// A cut never leaves an empty isolate: where a key fills a piece, the value's opening quotation mark and isolate
    /// go on to the next piece, which starts `↳ "`; closing punctuation stays with what it closes.
    @Test func aCutLeavesNoEmptyIsolateAndKeepsClosingPunctuation() {
        var carried = 0
        for n in 180...200 {
            let line = DocumentPresentation.RawLine(
                depth: 1, key: ShownText(String(repeating: "k", count: n), escaped: true),
                value: .string(ShownText("\u{202E}" + String(repeating: "v", count: 50), escaped: true)), comma: true
            )
            let pieces = DocPiece.raw(line)
            for p in pieces {
                for (i, t) in p.tokens.enumerated() where t == .open {
                    #expect(i + 1 < p.tokens.count && p.tokens[i + 1] != .close, "an empty isolate at \(n)")
                }
            }
            if pieces.count > 1, pieces[1].tokens.prefix(3) == [.punct(DocPiece.continued), .punct("\""), .open] { carried += 1 }
            #expect(pieces.last?.tokens.suffix(3) == [.close, .punct("\""), .punct(",")])
        }
        #expect(carried > 0, "the opening was carried over at least once")
        // A string that ends in an escape exactly at a forced cut leaves no empty isolate either.
        let tight = DocPiece.raw(Self.line(String(repeating: "x", count: 30) + #"""#), max: 30)
        for p in tight {
            for (i, t) in p.tokens.enumerated() where t == .open {
                #expect(i + 1 < p.tokens.count && p.tokens[i + 1] != .close)
            }
        }
    }

    @Test func gluingContinuationAndModifierCharactersAreMarkers() {
        // Every scalar that forms one character with a following backslash (Prepend, of this system's Unicode) is a marker.
        var glue = 0
        for v in UInt32(0x20)...0x2FFFF {
            guard let u = Unicode.Scalar(v), ShownText.gluesForward(u) else { continue }
            glue += 1
            #expect(ShownText(String(Character(u))).runs == [.marker(v)], "U+\(String(v, radix: 16))")
        }
        #expect(glue > 10)
        for v: UInt32 in [0x21B3, 0x21AA, 0x2937, 0x21B4, 0x2BA1, 0x2514, 0x2570, 0x21B5, 0x23CE, 0x27A5, 0x2935, 0x221F, 0x2517] {
            #expect(ShownText("a" + String(Character(Unicode.Scalar(v)!)) + "b").runs == [.text("a"), .marker(v), .text("b")])
        }
        #expect(ShownText("\u{1F3FD}x").runs == [.marker(0x1F3FD), .text("x")], "a skin tone with no base")
        #expect(ShownText("\u{1F44D}\u{1F3FD}").runs == [.text("\u{1F44D}\u{1F3FD}")], "with its base")
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
        // Spacing marks (Mc) are not counted in the row: ordinary Burmese ("ပြော", "ကြိုး") shows no marker.
        for word in ["\u{1015}\u{103C}\u{1031}\u{102C}", "\u{1000}\u{103C}\u{102D}\u{102F}\u{1038}"] {
            #expect(ShownText(word).runs == [.text(word)], "\(word)")
        }
    }
}
