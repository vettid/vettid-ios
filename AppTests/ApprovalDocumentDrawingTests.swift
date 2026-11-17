import SwiftUI
import Testing
import UIKit
import VettIDApprovals
@testable import VettIDApprovalsUI
import VettIDCrypto
import VettIDData
import VettIDUI

// Documents stay on one line each.
// swiftlint:disable line_length

/// An approval's document drawn on the device itself (VAULT-MESSAGING 0.89.0 §10.4 "Approval documents"): a value of
/// 65 KB at the largest text size is drawn to its end, not blank past a layer's limit, so what the screen counts as seen
/// was drawn. The package's own tests check the same on the simulator; layer limits differ on a phone, so this runs in
/// the app (the VettIDDevice scheme, `-only-testing:VettIDTests`).
@MainActor
@Suite(.serialized) struct ApprovalDocumentDrawingTests {
    static func shown(_ doc: String) throws -> DocumentStep {
        let b = Array(doc.utf8)
        let d = Bytes.sha256(b)
        let r = ApprovalDocument.check(
            Base64s.encodeStd(b), sha256: Base64s.encodeStd(d), size: b.count, context: "x — ref " + ApprovalDocument.ref(d)
        )
        guard case .success(let checked) = r else { throw CocoaError(.coderInvalidValue) }
        return .shown(checked, try #require(DocumentPresentation(checked, context: "x")))
    }

    private func host(_ content: some View) throws -> (UIWindow, UIScrollView) {
        let root = ScrollView { content.padding(Spacing.xl) }.vettIDTheme(.light).dynamicTypeSize(.accessibility5)
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
                let sum = Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])
                if sum < 200 { dark += 1 } else if sum > 600 { light += 1 }
            }
        }
        return (dark, light)
    }

    /// The control: the same capture shows text for a short value, so a blank capture below is the value's, not the
    /// capture's.
    @Test func aShortValueIsDrawn() async throws {
        let doc = #"{"action":"x","payload":{"s":"\#(Array(repeating: "budget", count: 40).joined(separator: " "))"},"summary":""}"#
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

    @Test func theTallestValuesAreDrawnToTheirEndOnThisDevice() async throws {
        let words = Array(repeating: "budget", count: 9_000).joined(separator: " ")
        let motion = #"{"action":"proposal.create","payload":{"binding":true,"choices":[],"closes_at":2,"opens_at":1,"outage_rule":"","quorum":{"min_ballots":1,"text":""},"removed_may_vote":false,"text":"\#(words)","title":"t"},"summary":""}"#
        let raw = #"{"action":"x","payload":{"s":"\#(words)"},"summary":""}"#
        for (doc, last) in [(motion, 0.9), (raw, 0.97)] {
            let t0 = Date()
            let view = ApprovalDocumentView(step: try Self.shown(doc), name: nil, seen: true, onRetry: {}, onSeenWhole: { _ in })
            let (window, scroll) = try host(view)
            print("DOC_TIMING: laid out in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            try await Task.sleep(for: .milliseconds(800))
            let height = scroll.contentSize.height
            #expect(height > 20_000, "a value taller than any layer")
            for at in [0.25, 0.5, 0.75, last] {
                // A lazy stack's height is an estimate until its rows are drawn: read again at every sample.
                let height = scroll.contentSize.height
                scroll.setContentOffset(CGPoint(x: 0, y: (height - scroll.bounds.height) * at), animated: false)
                // Long enough on screen for a screenshot of the phone itself (`VETTID_TEST_DOC_HOLD`, seconds).
                let hold = Double(ProcessInfo.processInfo.environment["VETTID_TEST_DOC_HOLD"] ?? "") ?? 0.5
                try await Task.sleep(for: .seconds(hold))
                let (dark, light) = pixels(window)
                print("DOC_DRAWN: \(at) of \(Int(height)) pt: \(dark) dark, \(light) light samples")
                #expect(dark > 500 && light > 500, "drawn at \(at) of \(Int(height)) pt")
            }
            window.isHidden = true
        }
    }
}

// swiftlint:enable line_length
