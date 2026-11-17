import Foundation
import Testing
@testable import VettIDApprovals
@testable import VettIDData

// Documents stay on one line each.
// swiftlint:disable line_length

/// What the approval screen shows of a document (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): the text rules
/// (markers, kept line breaks), the forms only for a payload that matches them exactly, the raw view of anything else,
/// and the times.
@Suite struct DocumentPresentationTests {
    func markers(_ t: ShownText) -> [UInt32] {
        t.runs.compactMap { if case .marker(let v) = $0 { v } else { nil } }
    }

    @Test func everyCharacterThatCouldReorderHideOrImitateIsAMarker() {
        let marked: [UInt32] = [
            0x0000, 0x0009, 0x000D, 0x001F, 0x007F, 0x0085, // Cc
            0x00AD, 0x200B, 0x200C, 0x200D, 0x200E, 0x202E, 0x2066, 0x2069, 0xFEFF, // Cf: the joiners and bidi controls
            0x2028, 0x2029, // Zl, Zp
            0xE000, 0xF0000, // Co
            0x0378, 0xFFFF, // Cn
            0x3164, 0x115F, 0xFE0F, 0xFE00, 0x034F, // other Default_Ignorable: Hangul fillers, variation selectors, CGJ
            0x00A0, 0x2003, 0x3000, // Zs other than U+0020
        ]
        for v in marked {
            let s = "a" + String(Character(Unicode.Scalar(v)!)) + "b"
            #expect(markers(ShownText(s)) == [v], "U+\(String(v, radix: 16))")
        }
        #expect(ShownText("a b é ש ١").runs == [.text("a b é ש ١")])
        #expect(ShownText.marker(0x202E) == "⟨U+202E⟩" && ShownText.marker(0xF0000) == "⟨U+F0000⟩")
        // Plain text, never markup or links.
        #expect(ShownText("**x** <b>y</b> https://example.org").runs == [.text("**x** <b>y</b> https://example.org")])
    }

    @Test func aThirdCombiningMarkInARowIsAMarker() {
        let two = "e\u{0301}\u{0302}"
        #expect(ShownText(two).runs == [.text(two)])
        #expect(ShownText("e\u{0301}\u{0302}\u{0303}\u{20DD}x").runs == [.text("e\u{0301}\u{0302}"), .marker(0x0303), .marker(0x20DD), .text("x")])
        // A mark after something else starts counting again.
        #expect(markers(ShownText("e\u{0301}\u{0302}a\u{0301}\u{0302}")).isEmpty)
    }

    @Test func noTextCanSpellAMarkerOrDecorateTheAppsOwnCharacters() {
        // The brackets a marker is drawn with are markers themselves.
        #expect(ShownText("\u{27E8}U+202E\u{27E9}").runs == [.marker(0x27E8), .text("U+202E"), .marker(0x27E9)])
        let lookAlikes: [UInt32] = [
            0x2329, 0x232A, 0x3008, 0x3009, 0x276C, 0x276D, 0x2039, 0x203A, 0x276E, 0x276F, 0x27EA, 0x27EB, 0xFF1C, 0xFF1E,
            0x29FC, 0x29FD, 0x2991, 0x2992, 0x2770, 0x2771, 0x300A, 0x300B, 0xFE64, 0xFE65, 0x02C2, 0x02C3, 0x1438, 0x1433,
            0x2800, 0xFFFC,
        ]
        for v in lookAlikes {
            #expect(ShownText("a" + String(Character(Unicode.Scalar(v)!)) + "b").runs == [.text("a"), .marker(v), .text("b")])
        }
        // A combining mark with no base in its run would combine with a quotation mark or a marker drawn before it.
        #expect(ShownText("\u{0338}x").runs == [.marker(0x0338), .text("x")])
        #expect(ShownText("\u{202E}\u{20DD}x").runs == [.marker(0x202E), .marker(0x20DD), .text("x")])
        #expect(ShownText("a\n\u{0301}", lineBreaks: true).runs == [.text("a"), .lineBreak, .marker(0x0301)])
        // A spacing mark (Mc) or any other grapheme extender with no base, too; with a base it stays.
        #expect(ShownText("\u{0903}x").runs == [.marker(0x0903), .text("x")])
        #expect(ShownText("\u{0915}\u{0903}").runs == [.text("\u{0915}\u{0903}")])
    }

    @Test func aRawStringShowsItsQuotesAndBackslashesEscaped() {
        let s = #"ann", "amount": 10 \ x"#
        #expect(ShownText(s, escaped: true).runs == [.text(#"ann\", \"amount\": 10 \\ x"#)])
        #expect(ShownText(s).runs == [.text(s)], "only in the raw view")
    }

    @Test func coverageCountsOnlyWhatWasSeenFromTheTopWithoutAGap() {
        var c = SeenCoverage()
        c.saw(0...300, height: 1000)
        #expect(!c.whole && c.seenTo == 300)
        // A jump past the middle (to the password field below) does not count.
        c.saw(700...1000, height: 1000)
        #expect(!c.whole && c.seenTo == 300)
        // The middle seen later (scrolling back) joins what was seen on both sides of it.
        c.saw(250...700, height: 1000)
        #expect(c.whole)
        // Another height (a new text size, a document shown again) starts again from the top.
        var d = SeenCoverage()
        d.saw(0...500, height: 1000)
        d.saw(400...1000, height: 1200)
        #expect(!d.whole && d.seenTo == 0)
        d.saw(nil, height: 1200)
        #expect(!d.whole)
        // A document that fits is seen at once; a part that starts below the top first is not.
        var e = SeenCoverage()
        e.saw(0...200, height: 200)
        #expect(e.whole)
        var f = SeenCoverage()
        f.saw(1...200, height: 200)
        #expect(f.whole, "within a point")
        var g = SeenCoverage()
        g.saw(5...200, height: 200)
        #expect(!g.whole)
    }

    @Test func aLongTextIsCutIntoBoundedPiecesWithNothingLostOrMarkerCut() {
        let words = Array(repeating: "budget", count: 3_000).joined(separator: " ")
        let t = ShownText(words + "\u{202E}" + words)
        let pieces = t.pieces()
        #expect(pieces.count > 100)
        #expect(pieces.allSatisfy { $0.plain.count <= ShownText.pieceCharacters })
        #expect(pieces.map(\.plain).joined() == t.plain, "nothing lost or added")
        #expect(pieces.contains { $0.runs.contains(.marker(0x202E)) }, "the marker whole, in one piece")
        // One word longer than a piece is cut at the bound.
        let long = ShownText(String(repeating: "x", count: 450)).pieces()
        #expect(long.map(\.plain) == [String(repeating: "x", count: 200), String(repeating: "x", count: 200), String(repeating: "x", count: 50)])
        // A kept line break once a piece is half full is the break between pieces.
        let lines = ShownText(String(repeating: "a", count: 150) + "\n" + "b", lineBreaks: true).pieces()
        #expect(lines.map(\.plain) == [String(repeating: "a", count: 150), "b"])
        #expect(ShownText("").pieces() == [ShownText("")])
    }

    @Test func lineBreaksAreKeptOnlyWhereTheFieldKeepsThem() {
        #expect(ShownText("a\nb").runs == [.text("a"), .marker(0x0A), .text("b")])
        #expect(ShownText("a\nb", lineBreaks: true).runs == [.text("a"), .lineBreak, .text("b")])
        #expect(ShownText("a\n\n\n\nb", lineBreaks: true).runs == [.text("a"), .lineBreak, .lineBreak, .marker(0x0A), .marker(0x0A), .text("b")])
        #expect(ShownText("a\r\nb", lineBreaks: true).runs == [.text("a"), .marker(0x0D), .lineBreak, .text("b")])
    }

    @Test func theVectorsVoteIsShownInItsForm() throws {
        let p = try #require(DocumentPresentation(DocumentSamples.checked(DocumentSamples.proposal), context: "ctx"))
        #expect(p.asked == .known(.proposalCreate) && p.context == ShownText("ctx") && p.summary == ShownText("Adopt the 2027 budget"))
        guard case .proposal(let f) = p.request else { throw CocoaError(.coderInvalidValue) }
        #expect(f.title == ShownText("Adopt the 2027 budget"))
        #expect(f.text?.runs == [.text("The members adopt the 2027 budget as circulated on 2026-11-20."), .lineBreak, .text("The board reports on it quarterly.")])
        #expect(f.choices == [ShownText("Yes"), ShownText("No")] && f.quorumBallots == 10 && f.quorumText == ShownText("A tenth of the members."))
        #expect(f.binding && !f.removedMayVote && f.opensAt == 1_796_115_600 && f.closesAt == 1_796_720_400)
        #expect(f.outageRule == ShownText("Extended by a relay outage over 1 hour, 24 h at most."))
    }

    static func proposal(_ payload: String) -> String { #"{"action":"proposal.create","payload":\#(payload),"summary":"s"}"# }
    static let good = #"{"binding":false,"choices":[],"closes_at":0,"opens_at":253402300799,"outage_rule":"","quorum":{"min_ballots":0,"text":""},"removed_may_vote":true,"text":"","title":""}"#

    @Test func anEmptyMotionOrQuorumTextIsNoneNotAValue() throws {
        let p = try #require(DocumentPresentation(DocumentSamples.checked(Self.proposal(Self.good)), context: nil))
        guard case .proposal(let f) = p.request else { throw CocoaError(.coderInvalidValue) }
        #expect(f.text == nil && f.quorumText == nil && f.choices.isEmpty && f.opensAt == DocumentPresentation.maxTime && p.context == nil)
    }

    @Test func aPayloadThatDoesNotMatchItsFormExactlyIsShownWhole() throws {
        let mismatched = [
            Self.good.replacingOccurrences(of: #""binding":false,"#, with: ""), // missing
            Self.good.replacingOccurrences(of: #""binding":false,"#, with: #""binding":false,"extra":1,"#), // extra
            Self.good.replacingOccurrences(of: #""binding":false"#, with: #""binding":"false""#), // another type
            Self.good.replacingOccurrences(of: #""opens_at":253402300799"#, with: #""opens_at":253402300800"#), // past 9999
            Self.good.replacingOccurrences(of: #""choices":[]"#, with: #""choices":[{"label":"a","x":1}]"#), // deeper extra
            Self.good.replacingOccurrences(of: #""choices":[]"#, with: #""choices":["a"]"#),
            Self.good.replacingOccurrences(of: #""min_ballots":0,"#, with: ""),
            Self.good.replacingOccurrences(of: #""text":""}"#, with: #""text":null}"#),
        ]
        for payload in mismatched {
            let p = try #require(DocumentPresentation(DocumentSamples.checked(Self.proposal(payload)), context: nil))
            guard case .raw(let lines) = p.request else { Issue.record("a form for \(payload)"); continue }
            #expect(lines.first == .init(depth: 0, key: nil, value: .open(.object), comma: false))
        }
    }

    @Test func voteExtendHasItsForm() throws {
        let doc = #"{"action":"vote.extend","payload":{"closes_at":1796720400,"outage":{"from":1,"source":"relay","to":2},"proposal_id":"p1"},"summary":"Extend"}"#
        let p = try #require(DocumentPresentation(DocumentSamples.checked(doc), context: nil))
        #expect(p.asked == .known(.voteExtend))
        #expect(p.request == .extend(.init(proposalID: ShownText("p1"), closesAt: 1_796_720_400, outageFrom: 1, outageTo: 2, outageSource: ShownText("relay"))))
        let other = doc.replacingOccurrences(of: #""to":2"#, with: #""to":2,"by":"x""#)
        guard case .raw = try #require(DocumentPresentation(DocumentSamples.checked(other), context: nil)).request else {
            throw CocoaError(.coderInvalidValue)
        }
    }

    @Test func aKnownActionWithoutAFormAndAnUnknownOneAreShownWhole() throws {
        let add = #"{"action":"admin_set.add","payload":{"n":10,"s":"10","t":true,"u":"true","z":null,"a":[],"o":{}},"summary":"Add Ann"}"#
        let p = try #require(DocumentPresentation(DocumentSamples.checked(add), context: nil))
        #expect(p.asked == .known(.adminSetAdd))
        guard case .raw(let lines) = p.request else { throw CocoaError(.coderInvalidValue) }
        let key = { (s: String) in ShownText(s) }
        #expect(lines == [
            .init(depth: 0, key: nil, value: .open(.object), comma: false),
            .init(depth: 1, key: key("action"), value: .string(ShownText("admin_set.add")), comma: true),
            .init(depth: 1, key: key("payload"), value: .open(.object), comma: false),
            .init(depth: 2, key: key("a"), value: .empty(.array), comma: true),
            .init(depth: 2, key: key("n"), value: .number("10"), comma: true),
            .init(depth: 2, key: key("o"), value: .empty(.object), comma: true),
            .init(depth: 2, key: key("s"), value: .string(ShownText("10")), comma: true),
            .init(depth: 2, key: key("t"), value: .bool(true), comma: true),
            .init(depth: 2, key: key("u"), value: .string(ShownText("true")), comma: true),
            .init(depth: 2, key: key("z"), value: .null, comma: false),
            .init(depth: 1, key: nil, value: .close(.object), comma: true),
            .init(depth: 1, key: key("summary"), value: .string(ShownText("Add Ann")), comma: false),
            .init(depth: 0, key: nil, value: .close(.object), comma: false),
        ])
        let unknown = #"{"action":"treasury.spend","payload":{"k":["\#u{202E}evil",1]},"summary":"Spend"}"#
        let u = try #require(DocumentPresentation(DocumentSamples.checked(unknown), context: nil))
        #expect(u.asked == .unknown("treasury.spend"))
        guard case .raw(let raw) = u.request else { throw CocoaError(.coderInvalidValue) }
        #expect(raw.contains(.init(depth: 3, key: nil, value: .string(ShownText("\u{202E}evil")), comma: true)))
        #expect(ShownText("\u{202E}evil").runs == [.marker(0x202E), .text("evil")])
    }

    @Test func timesAreShownInTheMembersZoneAndInUtcWithSecondsOnlyWhenNotZero() throws {
        let locale = Locale(identifier: "en_US")
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let t = DocumentTime.shown(1_796_720_400, zone: zone, locale: locale)
        #expect(t.local.contains("2026") && t.local.contains("EST") && !t.local.contains(":00:"))
        #expect(t.utc.hasSuffix(" UTC") && !t.utc.contains("GMT") && t.utc.contains("9:00"))
        let s = DocumentTime.shown(1_796_720_401, zone: zone, locale: locale)
        #expect(s.local.contains(":01") && s.utc.contains(":01"))
        #expect(DocumentTime.shown(DocumentPresentation.maxTime, zone: zone, locale: locale).utc.contains("9999"))
    }
}

// swiftlint:enable line_length
