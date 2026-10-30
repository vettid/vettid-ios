#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData
import VettIDUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Approvals screens: every state of the list and of a decision rendered (each kind of request, the gone screen, a
/// critical use's result, a backoff, the password field), the safety code and the data to sign kept out of captures, and
/// a decided request's screen closing. Mirrors vettid-android's Approvals screen tests.
@MainActor
@Suite struct ApprovalsScreensTests {
    private var chrome: ShellChrome { ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {}) }

    @Test func everyListStateRenders() {
        for s in listStates() {
            #expect(height(ApprovalsScreen(state: s, chrome: chrome, actions: ApprovalsActions())) > 0, "\(s)")
        }
    }

    @Test func everyDecisionRenders() {
        for s in detailStates() {
            #expect(height(ApprovalDetailScreen(state: s, actions: DecisionActions())) > 0, "\(s)")
        }
    }

    /// A batch's row lists its asks once opened.
    @Test func aBatchOpensAndCloses() {
        let asks = [Samples.auth("a1"), Samples.grant("g1", at: Samples.t0.addingTimeInterval(60))]
        var toggled = 0
        let row = BatchRow(key: "batch:auth:a1", asks: asks, receivedAt: Samples.t0, name: "Sam Lee", open: true, onOpen: { _ in }) { toggled += 1 }
        #expect(height(row) > height(BatchRow(key: "b", asks: asks, receivedAt: Samples.t0, name: nil, open: false, onOpen: { _ in }) {}))
        #expect(BatchRow.kinds(asks + [Samples.auth("a3")]) == "Authenticate to a connection · Request to see your items")
        #expect(BatchRow.kinds([Samples.auth("a4", purpose: .signin)] + asks, name: "Sam") == "Sign in to \(AccountNames.isolate("Sam"))? · Authenticate to a connection · Request to see your items")
        #expect(toggled == 0)
    }

    /// A request decided here closes its screen.
    @Test func aDecidedRequestCloses() {
        var closed = 0
        var actions = DecisionActions()
        actions.onBack = { closed += 1 }
        var state = ApprovalDetailState(key: "auth:a1")
        state.approval = Samples.auth()
        state.done = true
        _ = host(ApprovalDetailScreen(state: state, actions: actions))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(closed >= 1)
    }

    /// IOS-PLAN §6.4: a request's safety code and a critical use's data to sign on the secure layer, unless screenshots
    /// are allowed.
    @Test func codesAreKeptOutOfCaptures() {
        guard SecureLayer.isAvailable else { return }
        for approval in [PendingApproval.connection(Samples.incoming()), Samples.critical()] {
            var s = ApprovalDetailState(key: approval.key)
            s.approval = approval
            let screen = ApprovalDetailScreen(state: s, actions: DecisionActions())
            let protected = host(screen.environment(ScreenshotAllowance(onByDefault: false)))
            #expect(views(in: protected).contains(where: onSecureLayer), "\(approval.key)")
            let allowed = host(screen.environment(ScreenshotAllowance(onByDefault: true)))
            #expect(views(in: protected).filter(onSecureLayer).count > views(in: allowed).filter(onSecureLayer).count, "\(approval.key)")
        }
    }

    private func listStates() -> [ApprovalsState] {
        var loading = ApprovalsState()
        loading.loading = true
        var failed = ApprovalsState()
        failed.loading = false
        failed.error = .network
        var empty = ApprovalsState()
        empty.loading = false
        var full = ApprovalsState()
        full.loading = false
        full.busy = true
        full.error = .network
        let sam = Samples.connection("c1", paused: true)
        full.connections = ["c1": sam]
        full.paused = [sam, Samples.connection("c2", first: nil, paused: true)]
        full.confirmRemove = sam
        full.peerDeclines = [PeerDecline(requestID: "r", name: nil, outgoing: false, at: Date())]
        full.approvals = [
            .connection(Samples.incoming()), .connection(Samples.outgoing(sas: nil)), Samples.auth(),
            Samples.auth("a2", purpose: .signin), Samples.auth("a3", purpose: .approval), Samples.grant(at: Samples.t0.addingTimeInterval(60)), Samples.critical(conn: "c9"), Samples.share(), Samples.device(),
        ]
        return [loading, failed, empty, full]
    }

    private func detailStates() -> [ApprovalDetailState] {
        let kinds: [PendingApproval] = [
            .connection(Samples.incoming()), .connection(Samples.incoming(state: .approved)), .connection(Samples.outgoing()),
            .connection(Samples.outgoing(sas: nil, state: .waiting)), Samples.auth(), Samples.grant(), Samples.critical(),
            Samples.critical("k2", payload: ""), Samples.critical("k3", payload: "b3RoZXI=", kind: "number"), Samples.share(), Samples.device(),
        ]
        var out: [ApprovalDetailState] = kinds.map { a in
            var s = ApprovalDetailState(key: a.key)
            s.approval = a
            s.connectionName = "Sam Lee"
            s.items = [AnswerItem(id: "x", name: "Card", category: "insurance")]
            return s
        }
        var failing = out[4]
        failing.password = "pw"
        failing.error = .badPassword
        failing.busy = true
        failing.confirmBlock = true
        var backoff = out[6]
        backoff.error = .backoff
        backoff.retryUntil = Date().addingTimeInterval(20)
        var limit = out[5]
        limit.error = .limit
        limit.limit = VaultLimit("grants_given", max: 3)
        limit.grantAnswers = [2: "x"]
        limit.grantUses = 10
        var result = out[6]
        result.criticalResult = "ok"
        var unsuitable = out[6]
        unsuitable.criticalResult = "unsuitable"
        var gone = out[0]
        gone.gone = true
        var notHeld = ApprovalDetailState(key: "auth:a9")
        notHeld.notHeld = true
        out += [failing, backoff, limit, result, unsuitable, gone, notHeld, ApprovalDetailState(key: "none")]
        out += [AuthenticationPurpose.signin, .approval].map { p in
            var s = out[4]
            s.approval = Samples.auth("a\(p)", purpose: p)
            return s
        }
        var coded = out[4]
        coded.approval = Samples.auth("am", purpose: .signin, matchCode: "07")
        out.append(coded)
        return out
    }

    /// A sign-in with a match code: its block adds to the screen, and the digits are never cut at the largest text size.
    @Test func theMatchCodeShowsAtEverySize() {
        func facts(_ code: String?) -> CGFloat {
            let view = Facts(approval: Samples.auth("am", purpose: .signin, matchCode: code), name: "VettID Member Service")
            return UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 2000)).height
        }
        #expect(facts("42") > facts(nil) + 40)
        let large = UIHostingController(rootView: MatchCodeBlock(code: "123").environment(\.dynamicTypeSize, .accessibility5).vettIDTheme(.light))
        let fit = large.sizeThatFits(in: CGSize(width: 320, height: 2000))
        let normal = UIHostingController(rootView: MatchCodeBlock(code: "123").vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 320, height: 2000))
        #expect(fit.width <= 320 && fit.height > normal.height)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    /// The secure text field's layout canvas, which ``SecureContainer`` hosts its content on (VettIDUI `SecureLayer`).
    private func onSecureLayer(_ v: UIView) -> Bool { String(describing: type(of: v)).contains("Canvas") }
}
// swiftlint:enable line_length
#endif
