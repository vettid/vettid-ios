import Foundation
import Testing
@testable import VettIDData

/// ANDROID-PLAN 0.1.116 AA5, decision 18: an `item.use`'s data is shown as text only when it is printable UTF-8, else as hex.
/// Mirrors vettid-android `DataViewTest`.
@Suite struct DataViewTests {
    private func view(_ s: String) -> DataView? { DataView.of(Array(s.utf8)) }

    @Test func printableUtf8IsShownAsText() {
        #expect(view("hello, wörld\nsecond line\twith a tab") == .text("hello, wörld\nsecond line\twith a tab"))
        #expect(view("日本語 עברית") == .text("日本語 עברית"))
    }

    @Test func anythingThatCouldHideOrFakeWhatIsReadIsHex() {
        let bad = [
            "a\u{202E}b", "a\u{200B}b", "a\u{00AD}b", "a\u{FE0F}b", "a\u{3164}b", "a\u{115F}b", "a\u{034F}b", "a\u{2800}b", "a\u{E000}b",
            "a\u{2028}b", "a\u{2029}b", "a\u{0007}b", "a\u{0000}b", "a\r\nb", "a\u{FEFF}b", "a\u{E0041}b", "a\u{0378}b",
        ]
        for s in bad {
            let codes = s.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
            #expect(view(s) == .hex(DataView.hex(Array(s.utf8))), Comment(rawValue: codes))
        }
    }

    @Test func invalidUtf8AndTooManyLinesOrMarksOrBlanksAreHex() {
        #expect(DataView.of([0xFF, 0xFE, 0x41]) == .hex("ff fe 41"))
        #expect(DataView.of([0xC3]) == .hex("c3"), "a cut sequence")
        #expect(DataView.of([0xED, 0xA0, 0x80]) == .hex("ed a0 80"), "an encoded surrogate")
        #expect(DataView.of([0xEF, 0xBB, 0xBF, 0x41]) == .hex("ef bb bf 41"), "a byte order mark is not dropped")
        #expect(view(String(repeating: "x\n", count: 7) + "x") == .text(String(repeating: "x\n", count: 7) + "x"))
        #expect(view(String(repeating: "x\n", count: 8) + "x") != .text(String(repeating: "x\n", count: 8) + "x"))
        #expect(view("a" + String(repeating: "\u{0301}", count: 2)) != .hex(""), "two marks")
        if case .text = view("a" + String(repeating: "\u{0301}", count: 3)) { Issue.record("three combining marks on one base") }
        if case .text = view("a" + String(repeating: " ", count: 9) + "b") { Issue.record("a run of blanks") }
        if case .text = view("a" + String(repeating: "\u{2003}", count: 9) + "b") { Issue.record("a run of wide blanks") }
        #expect(view("a" + String(repeating: " ", count: 8) + "b") == .text("a" + String(repeating: " ", count: 8) + "b"))
    }

    /// No more than `item.use`'s own bound (§10.11) is ever shown, as text or as hex.
    @Test func moreThanTheDataBoundIsNotShownAtAll() {
        #expect(DataView.maxBytes == 16_384)
        #expect(DataView.of(Array(repeating: 0x61, count: 16_384)) == .text(String(repeating: "a", count: 16_384)))
        #expect(DataView.of(Array(repeating: 0x61, count: 16_385)) == nil)
        #expect(DataView.of(Array(repeating: 0xFF, count: 16_385)) == nil)
    }

    @Test func hexIsLowerCaseTwoDigitsASpaceBetween() {
        #expect(DataView.hex([0, 1, 0xAB, 0xFF]) == "00 01 ab ff" && DataView.hex([]) == "")
    }
}
