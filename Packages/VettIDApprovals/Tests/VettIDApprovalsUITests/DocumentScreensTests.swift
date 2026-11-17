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
@MainActor
@Suite struct DocumentScreensTests {
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
        return .shown(d, DocumentPresentation(d, context: "Approve on Example Service: New vote: Adopt the 2027 budget (full text attached) — ref " + ApprovalDocument.ref(d.d)))
    }

    func view(_ step: DocumentStep, seen: Bool = false) -> some View {
        ApprovalDocumentView(step: step, name: "Example Service", seen: seen, onRetry: {}, onSeenWhole: {})
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

    @Test func theRawViewKeepsStringsApartFromNumbers() throws {
        guard case .shown(_, let p) = Self.shown(Self.unknown), case .raw(let lines) = p.request else { throw CocoaError(.coderInvalidValue) }
        let spoken = lines.map(RawDocumentView.spoken)
        #expect(spoken.contains("amount: 10, text") && spoken.contains("count: 10"))
        #expect(spoken.contains { $0.hasPrefix("note:") && $0.contains("code point U+202E") })
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
