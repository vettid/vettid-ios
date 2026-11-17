#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDApprovals
@testable import VettIDApprovalsUI
import VettIDCrypto
@testable import VettIDData
import VettIDUI

// Documents stay on one line each.
// swiftlint:disable line_length

/// An approval's document on the decision screen (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): every step
/// renders, the raw view keeps strings apart from numbers and isolates each key and string, VoiceOver reads markers as
/// code points. With `VETTID_DOC_SHOTS` set to a folder, the screens are also written there as PNG (for the texts' review).
/// Serialized: its windows and its largest documents take the memory and the main thread of the test process.
@MainActor
@Suite(.serialized) struct DocumentScreensTests {
    static let vote = #"{"action":"proposal.create","payload":{"binding":true,"choices":[{"label":"Yes"},{"label":"No"}],"closes_at":1796720400,"opens_at":1796115600,"outage_rule":"Extended by a relay outage over 1 hour, 24 h at most.","quorum":{"min_ballots":10,"text":"A tenth of the members."},"removed_may_vote":false,"text":"The members adopt the 2027 budget as circulated on 2026-11-20.\nThe board reports on it quarterly.","title":"Adopt the 2027 budget"},"summary":"Adopt the 2027 budget"}"#
    static let unknown = #"{"action":"treasury.spend","payload":{"amount":"10","count":10,"note":"\#u{202E}evil","to":["ann","\#u{05E9}\#u{05DC}\#u{05D5}\#u{05DD}"]},"summary":"Spend from the treasury"}"#

    static func checked(_ doc: String) -> ApprovalDocument {
        let b = Array(doc.utf8)
        let context = "Approve on Example Service — ref " + ApprovalDocument.ref(Bytes.sha256(b))
        guard case .success(let d) = ApprovalDocument.check(
            Base64s.encodeStd(b), sha256: Base64s.encodeStd(Bytes.sha256(b)), size: b.count, context: context
        ) else { fatalError("sample document refused") }
        return d
    }

    static func shown(_ doc: String) -> DocumentStep {
        let d = checked(doc)
        // swiftlint:disable:next force_unwrapping
        return .shown(d, DocumentPresentation(d, context: "Approve on Example Service: New vote: Adopt the 2027 budget (full text attached) — ref " + ApprovalDocument.ref(d.d))!)
    }

    func view(_ step: DocumentStep, seen: Bool = false) -> some View {
        ApprovalDocumentView(step: step, name: "Example Service", seen: seen, onRetry: {}, onSeenWhole: { _ in })
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 10_000)).height
    }

    @Test func everyStepRenders() {
        let steps: [DocumentStep] = [.loading, .failed(.noResponse), .unshowable(.hash), Self.shown(Self.vote), Self.shown(Self.unknown)]
        for step in steps {
            #expect(height(view(step)) > 0, "\(step)")
        }
    }

    /// The largest documents (65,536 bytes) stay drawable, so that Deny stays in reach: a string of 65,000 markers, and an
    /// array of 32,000 elements, each rendered within a few seconds.
    @Test func theLargestDocumentsRender() {
        let head = #"{"action":"x","payload":{"s":""#, tail = #""},"summary":""}"#
        let markers = head + String(repeating: "\u{7F}", count: 65_536 - head.utf8.count - tail.utf8.count) + tail
        let zeros = #"{"action":"x","payload":{"a":["# + Array(repeating: "0", count: 32_700).joined(separator: ",") + #"]},"summary":""}"#
        for doc in [markers, zeros] {
            let start = Date()
            #expect(height(view(Self.shown(doc), seen: true)) > 0)
            #expect(Date().timeIntervalSince(start) < 20)
        }
    }

    // MARK: - In a window, scrolled as a member scrolls

    /// [content] in a scroll view, in a window on screen, at the largest Dynamic Type; with the scroll view found.
    private func host(_ content: some View) throws -> (UIWindow, UIScrollView) {
        let root = ScrollView { content.padding(Spacing.xl) }.vettIDTheme(.light).dynamicTypeSize(.accessibility5)
        let vc = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        func find(_ v: UIView) -> UIScrollView? { (v as? UIScrollView) ?? v.subviews.lazy.compactMap(find).first }
        return (window, try #require(find(vc.view)))
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(400)) }

    /// How many of the pixels in the middle band of what the window shows are dark (text on the light theme).
    private func darkPixels(_ window: UIWindow) -> Int {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        var dark = 0
        for y in stride(from: cg.height / 4, to: 3 * cg.height / 4, by: 4) {
            for x in stride(from: 0, to: cg.width, by: 4) {
                let o = y * bpr + x * bpp
                if Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2]) < 200 { dark += 1 }
            }
        }
        return dark
    }

    /// A value of 65 KB is drawn to its end at the largest text size, not blank past a layer's limit: what the coverage
    /// counts as seen was drawn. A Motion of one long paragraph, and the raw view of one long string.
    @Test func theTallestValuesAreDrawnToTheirEnd() async throws {
        let words = Array(repeating: "budget", count: 9_000).joined(separator: " ")
        let motion = #"{"action":"proposal.create","payload":{"binding":true,"choices":[],"closes_at":2,"opens_at":1,"outage_rule":"","quorum":{"min_ballots":1,"text":""},"removed_may_vote":false,"text":"\#(words)","title":"t"},"summary":""}"#
        let raw = #"{"action":"x","payload":{"s":"\#(words)"},"summary":""}"#
        // The Motion is followed by the form's other fields: its end is sampled at 0.9, the raw string's at 0.97.
        for (doc, last) in [(motion, 0.9), (raw, 0.97)] {
            let (window, scroll) = try host(view(Self.shown(doc), seen: true))
            await settle()
            let height = scroll.contentSize.height
            #expect(height > 20_000, "a value taller than any layer")
            for at in [0.25, 0.5, 0.75, last] {
                scroll.setContentOffset(CGPoint(x: 0, y: (height - scroll.bounds.height) * at), animated: false)
                await settle()
                #expect(darkPixels(window) > 500, "drawn at \(at) of \(Int(height)) pt")
            }
            window.isHidden = true
        }
    }

    /// Approve's report comes only once the document has been on screen from its top down: a jump to the end does not
    /// count, scrolling down to it does.
    @Test func aJumpToTheEndIsNotSeeingTheWhole() async throws {
        final class Box { var seen: [String] = [] }
        let box = Box()
        let doc = #"{"action":"x","payload":{"a":["# + Array(repeating: "0", count: 600).joined(separator: ",") + #"]},"summary":""}"#
        let step = Self.shown(doc)
        let content = ApprovalDocumentView(step: step, name: nil, seen: false, onRetry: {}, onSeenWhole: { box.seen.append($0) })
        let (window, scroll) = try host(content)
        await settle()
        let bottom = scroll.contentSize.height - scroll.bounds.height
        #expect(bottom > 2_000 && box.seen.isEmpty)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        await settle()
        #expect(box.seen.isEmpty, "a jump to the end")
        // A lazy stack's height is an estimate until its rows are drawn: the end is read again at every step.
        var y: CGFloat = 0
        while y < scroll.contentSize.height - scroll.bounds.height {
            y = min(y + scroll.bounds.height / 2, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            try? await Task.sleep(for: .milliseconds(80))
        }
        await settle()
        guard case .shown(let d, _) = step else { return }
        #expect(box.seen == [d.sha256], "scrolled down to the end")
        window.isHidden = true
    }

    @Test func theRawViewKeepsStringsApartFromNumbers() throws {
        guard case .shown(_, let p) = Self.shown(Self.unknown), case .raw(let lines) = p.request else { throw CocoaError(.coderInvalidValue) }
        let pieces = lines.flatMap { DocPiece.raw($0) }
        let spoken = pieces.map { Spoken.plain(Spoken.of($0, raw: true)) }
        #expect(spoken.first == "level 1, {")
        #expect(spoken.contains(#"level 3, "amount": "10","#) && spoken.contains(#"level 3, "count": 10,"#))
        #expect(spoken.contains(#"level 3, "note": "⟨U+202E⟩evil","#))
        // The quotation marks, the punctuation and the marker are the app's symbols (always spoken as punctuation), the
        // key and the string the document's content: content that says "level 2", a quotation mark or a marker is heard
        // and brailled as content, between the app's own marks.
        let note = try #require(pieces.first { Spoken.plain(Spoken.of($0, raw: true)).hasPrefix(#"level 3, "note"#) })
        let words = Spoken.of(note, raw: true)
        #expect(words == [
            .app("level 3, "), .symbol("\""), .content("note"), .symbol("\": "), .symbol("\""), .symbol("⟨U+202E⟩"),
            .content("evil"), .symbol("\""), .symbol(","),
        ])
        let a = Spoken.attributed(words)
        for run in a.runs {
            let text = String(a[run.range].characters)
            let isContent = text == "note" || text == "evil"
            let isApp = text.contains("level")
            #expect((run.accessibilitySpeechAdjustedPitch != nil) == isContent, "pitch on \(text)")
            #expect((run.accessibilitySpeechIncludesPunctuation == true) == (!isContent && !isApp), "punctuation on \(text)")
        }
        // Escaped content cannot close its quotes: a string's own quotation mark is read escaped, inside the app's.
        let sneaky = DocumentPresentation.RawLine(depth: 1, key: ShownText("k", escaped: true), value: .string(ShownText(#"x", "y"#, escaped: true)), comma: false)
        #expect(Spoken.plain(Spoken.of(DocPiece.raw(sneaky)[0], raw: true)) == #"level 2, "k": "x\", \"y""#)
        // A value's later piece is read as continued, between quotation marks: never as a value of its own.
        let value = DocPiece.value(ShownText("Yes " + String(repeating: "no ", count: 100)))
        #expect(Spoken.plain(Spoken.of(value[0], raw: false)).hasPrefix(#""Yes "#))
        #expect(Spoken.plain(Spoken.of(value[1], raw: false)).hasPrefix("↳ \""))
        // A value's own quotation marks are read escaped.
        #expect(Spoken.plain(Spoken.of(DocPiece.value(ShownText(#"a"b\c"#))[0], raw: false)) == #""a\"b\\c""#)
    }

    @Test func theTitlesAreTheSpecs() {
        let titles = DocumentPresentation.KnownAction.allCases.map(ApprovalDocumentView.title)
        #expect(titles == ["New vote", "Extend a vote", "Add an admin", "Remove an admin", "Re-pin an admin's key", "Change the contract template", "Send an assignment"])
        #expect(ApprovalsStrings.docUnknownWarning("Example Service") == "Example Service asks for something this app doesn't know. Read all of it before you approve.")
        #expect(ApprovalsStrings.docCantShow == "This request can't be shown")
        #expect(ApprovalsStrings.docBallots(1) == "1 ballot" && ApprovalsStrings.docBallots(10) == "10 ballots")
    }

    /// The screens for the texts' review, when asked for: before (an approval without a document) and with each kind.
    @Test func screensForTheTextsReview() throws {
        guard let dir = ProcessInfo.processInfo.environment["VETTID_DOC_SHOTS"] else { return }
        let request = AuthenticationRequest(requestID: "a1", connectionID: "c1", context: "Approve on Example Service: New vote: Adopt the 2027 budget — ref e8af8815891e434b", receivedAt: Date(), exp: nil, purpose: .approval)
        let shots: [(String, AnyView)] = [
            ("1-before", AnyView(screen(request, document: nil))),
            ("2-vote", AnyView(screen(request, document: Self.shown(Self.vote)))),
            ("3-unknown", AnyView(screen(request, document: Self.shown(Self.unknown)))),
            ("4-cant-show", AnyView(screen(request, document: .unshowable(.hash)))),
        ]
        for (name, v) in shots {
            for (scheme, label) in [(ThemeMode.light, "light"), (.dark, "dark")] {
                let r = ImageRenderer(content: v.frame(width: 390).vettIDTheme(scheme))
                r.scale = 2
                let data = try #require(r.uiImage?.pngData())
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(label).png"))
            }
        }
    }

    private func screen(_ r: AuthenticationRequest, document: DocumentStep?) -> some View {
        var r = r
        if document != nil { r.documentSha256 = "x" }
        let a = PendingApproval.authentication(r)
        return VStack(alignment: .leading, spacing: 0) {
            Text(ApprovalTexts.title(a, name: "Example Service")).vettIDFont(.headlineSmall).padding(.bottom, Spacing.m)
            Facts(approval: a, name: "Example Service", service: true)
            if let document { view(document, seen: true) }
        }
        .padding(Spacing.xl)
        .modifier(ThemedBackground())
    }
}

/// The theme's background behind a rendered screen.
private struct ThemedBackground: ViewModifier {
    @Environment(\.vettIDColors) private var colors
    func body(content: Content) -> some View { content.background(colors.background) }
}

// swiftlint:enable line_length
#endif
