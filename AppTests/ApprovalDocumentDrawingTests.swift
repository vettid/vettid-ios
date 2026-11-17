import SwiftUI
import Testing
import UIKit
import VettIDApprovals
@testable import VettIDApprovalsUI
import VettIDCrypto
import VettIDData
import VettIDUI

/// Only on a phone: the simulator draws what a phone does not.
private let onDevice: Bool = {
    #if targetEnvironment(simulator)
    false
    #else
    true
    #endif
}()

// Documents stay on one line each.
// swiftlint:disable line_length

/// An approval's document drawn on the device itself (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): a value of
/// 65 KB at the largest text size is drawn to its end, not blank past a layer's limit, so what the screen counts as seen
/// was drawn. The package's own tests check the same on the simulator; layer limits differ on a phone, so this runs in
/// the app (the VettIDDevice scheme, `-only-testing:VettIDTests`).
@MainActor
@Suite(.serialized, .enabled(if: onDevice, "layer limits are the phone's: the simulator draws what a phone does not"))
struct ApprovalDocumentDrawingTests {

    static func shown(_ doc: String) throws -> DocumentStep {
        let b = Array(doc.utf8)
        let d = Bytes.sha256(b)
        let r = ApprovalDocument.check(
            Base64s.encodeStd(b), sha256: Base64s.encodeStd(d), size: b.count, context: "x — ref " + ApprovalDocument.ref(d)
        )
        guard case .success(let checked) = r else { throw CocoaError(.coderInvalidValue) }
        return .shown(checked, try #require(DocumentPresentation(checked, context: "x")))
    }

    /// [content] in the decision screen's own scaffold (its scroll view, title and buttons), on screen, at the largest
    /// text size; with the scroll view found.
    private func host(_ content: some View) throws -> (UIWindow, UIScrollView) {
        let root = FormScaffold(title: "Example Service asks you to approve", primaryLabel: "Approve", onPrimary: {}) { content }
            .vettIDTheme(.light).dynamicTypeSize(.accessibility5)
        let vc = UIHostingController(rootView: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = vc
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        func find(_ v: UIView) -> UIScrollView? { (v as? UIScrollView) ?? v.subviews.lazy.compactMap(find).first }
        return (window, try #require(find(vc.view)))
    }

    /// How many sampled pixels of the middle band of what the window shows are dark and how many light: text on the light
    /// theme has both (an image all dark or all light is not text).
    private func pixels(_ window: UIWindow) -> (dark: Int, light: Int) {
        // 8 bits a component, sRGB: a phone's default is the extended range, 16 bits a component.
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return (0, 0) }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        var dark = 0, light = 0
        for y in stride(from: cg.height / 4, to: 3 * cg.height / 4, by: 4) {
            for x in stride(from: 0, to: cg.width, by: 4) {
                let o = y * bpr + x * bpp
                // Ink: text, or a marker's red; light: the page and the value's fill.
                let sum = Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])
                if sum < 500 { dark += 1 } else if sum > 600 { light += 1 }
            }
        }
        return (dark, light)
    }

    /// The control: the same capture shows text for a short value, so a blank capture below is the value's, not the
    /// capture's.
    @Test func aShortValueIsDrawn() async throws {
        let doc = #"{"action":"x","payload":{"s":"\#(Array(repeating: "budget", count: 150).joined(separator: " "))"},"summary":""}"#
        let view = ApprovalDocumentView(step: try Self.shown(doc), name: nil, seen: true, onRetry: {}, onSeenWhole: { _ in })
        let (window, scroll) = try host(view)
        try await Task.sleep(for: .milliseconds(800))
        scroll.setContentOffset(CGPoint(x: 0, y: min(1_500, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        try await Task.sleep(for: .milliseconds(800))
        let (dark, light) = pixels(window)
        print("DOC_DRAWN: control of \(Int(scroll.contentSize.height)) pt: \(dark) dark, \(light) light samples")
        #expect(dark > 500 && light > 500)
        window.isHidden = true
    }

    /// Samples what the screen shows at points through [view]'s height; every sample has text on it.
    private func sampled(_ view: some View, _ name: String, last: Double = 0.97) async throws {
        let t0 = Date()
        let (window, scroll) = try host(view)
        print("DOC_TIMING: \(name) laid out in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        try await Task.sleep(for: .milliseconds(800))
        for at in [0.25, 0.5, 0.75, last] {
            // A lazy stack's height is an estimate until its rows are drawn: read again at every sample.
            let height = scroll.contentSize.height
            scroll.setContentOffset(CGPoint(x: 0, y: (height - scroll.bounds.height) * at), animated: false)
            let hold = Double(ProcessInfo.processInfo.environment["VETTID_TEST_DOC_HOLD"] ?? "") ?? 0.5
            try await Task.sleep(for: .seconds(hold))
            let (dark, light) = pixels(window)
            print("DOC_DRAWN: \(name) at \(at) of \(Int(scroll.contentSize.height)) pt: \(dark) dark, \(light) light samples")
            #expect(dark > 500 && light > 500, "\(name) drawn at \(at)")
        }
        window.isHidden = true
    }

    static let words = Array(repeating: "budget", count: 9_000).joined(separator: " ")

    @Test func aLongMotionIsDrawnToItsEnd() async throws {
        let motion = #"{"action":"proposal.create","payload":{"binding":true,"choices":[],"closes_at":2,"opens_at":1,"outage_rule":"","quorum":{"min_ballots":1,"text":""},"removed_may_vote":false,"text":"\#(Self.words)","title":"t"},"summary":""}"#
        try await sampled(ApprovalDocumentView(step: try Self.shown(motion), name: nil, seen: true, onRetry: {}, onSeenWhole: { _ in }), "motion", last: 0.9)
    }

    @Test func aLongRawStringIsDrawnToItsEnd() async throws {
        let raw = #"{"action":"x","payload":{"s":"\#(Self.words)"},"summary":""}"#
        try await sampled(ApprovalDocumentView(step: try Self.shown(raw), name: nil, seen: true, onRetry: {}, onSeenWhole: { _ in }), "raw")
    }

    /// The shapes a service could choose to defeat the cuts: no white space at all, nothing but markers, and one
    /// character of 21,000 code points.
    @Test func adversarialValuesAreDrawnToTheirEnd() async throws {
        let unbroken = String(repeating: "x", count: 65_000)
        let markers = String(repeating: "\u{7F}", count: 65_000)
        let jamo = String(repeating: "\u{1100}", count: 21_000)
        for (name, s) in [("unbroken", unbroken), ("markers", markers), ("jamo", jamo)] {
            let doc = #"{"action":"x","payload":{"s":"\#(s)"},"summary":""}"#
            try await sampled(ApprovalDocumentView(step: try Self.shown(doc), name: nil, seen: true, onRetry: {}, onSeenWhole: { _ in }), name)
        }
    }

    /// The negative control: the layout this replaces, one text of 65 KB, is drawn blank on the phone. If a later iOS
    /// draws it, this says so (the pieces stay all the same).
    @Test func oneTextOf65KBIsDrawnBlankOnThePhone() async throws {
        let (window, scroll) = try host(Text(Self.words).font(.body))
        try await Task.sleep(for: .milliseconds(800))
        scroll.setContentOffset(CGPoint(x: 0, y: (scroll.contentSize.height - scroll.bounds.height) * 0.5), animated: false)
        try await Task.sleep(for: .milliseconds(500))
        let (dark, light) = pixels(window)
        print("DOC_DRAWN: single text at 0.5 of \(Int(scroll.contentSize.height)) pt: \(dark) dark, \(light) light samples")
        #expect(dark < 100, "one tall text is drawn on this phone after all")
        window.isHidden = true
    }
}

// swiftlint:enable line_length
