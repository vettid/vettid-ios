#if os(iOS)
import Foundation
import SwiftUI
import Testing
@testable import VettIDApprovalsUI

/// A document's texts in bounded pieces (``DocumentPieces``): nothing lost or added but the breaks between pieces, no
/// piece over the bound, no marker cut, and every isolate a cut falls in closed and opened again.
@Suite struct DocumentPiecesTests {
    @Test func piecesAreBoundedAndLoseNothing() {
        let words = Array(repeating: "budget", count: 400).joined(separator: " ")
        let pieces = DocumentPieces.pieces(AttributedString(words))
        #expect(pieces.count > 10 && pieces.allSatisfy { $0.characters.count <= DocumentPieces.maxCharacters })
        #expect(pieces.map { String($0.characters) }.joined() == words)
        // Each piece ends after a white space (none is cut inside a word).
        #expect(pieces.dropLast().allSatisfy { $0.characters.last == " " })
    }

    @Test func aPieceEndsAtAStyleChangeRatherThanInsideAMarker() {
        var text = AttributedString(String(repeating: "x", count: 195))
        var marker = AttributedString("⟨U+202E⟩")
        marker.underlineStyle = .single
        text += marker + AttributedString(String(repeating: "y", count: 300))
        let pieces = DocumentPieces.pieces(text)
        #expect(String(pieces[0].characters) == String(repeating: "x", count: 195))
        #expect(String(pieces[1].characters).hasPrefix("⟨U+202E⟩"))
        #expect(pieces.map { String($0.characters) }.joined() == String(text.characters))
    }

    @Test func aKeptLineBreakAtACutIsTheBreakBetweenPieces() {
        let text = String(repeating: "a", count: 150) + "\n" + String(repeating: "b", count: 150)
        let pieces = DocumentPieces.pieces(AttributedString(text))
        #expect(pieces.map { String($0.characters) } == [String(repeating: "a", count: 150), String(repeating: "b", count: 150)])
    }

    @Test func aRawLineCutInsideAnIsolateKeepsItIsolated() {
        let (lrm, fsi, pdi) = (RawDocumentView.lrm, RawDocumentView.fsi, RawDocumentView.pdi)
        let line = AttributedString(lrm + "  \"" + fsi + String(repeating: "\u{05E9}", count: 450) + pdi + "\",")
        let pieces = DocumentPieces.rawPieces(line).map { String($0.characters) }
        #expect(pieces.count >= 3)
        for (n, p) in pieces.enumerated() {
            #expect(p.hasPrefix(lrm), "piece \(n) starts left-to-right")
            #expect(p.filter { String($0) == fsi }.count == p.filter { String($0) == pdi }.count, "piece \(n) balanced")
        }
        #expect(pieces.last?.hasSuffix(pdi + "\",") == true)
    }
}
#endif
