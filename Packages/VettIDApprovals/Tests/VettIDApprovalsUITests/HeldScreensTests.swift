#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData
@testable import VettIDUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The screens of an agent's request held for approval (ANDROID-PLAN 0.1.116 AA5): each kind rendered from the item list, its
/// row, and the answer before the screen closes. Mirrors vettid-android's `DeviceAsksScreenTest`.
@MainActor
@Suite(.serialized) struct HeldScreensTests {
    private let items = [ItemSummary(
        itemID: "i1", version: 1, name: "GitHub", category: "login", sensitivity: .secret,
        fieldLabels: [ItemFieldLabel(fieldID: "f1", label: "Token", kind: "password"), ItemFieldLabel(fieldID: "f2", label: "User", kind: "text")]
    )]

    private func request(_ h: HeldApproval) -> DeviceRequest {
        DeviceRequest(type: "approval.pending", id: "h1", deviceName: "Bot", role: "agent", requestType: "agent.request", receivedAt: Samples.t0, exp: Date().addingTimeInterval(300), deviceID: "A", held: h)
    }

    private func state(_ h: HeldApproval, loaded: Bool = true) -> ApprovalDetailState {
        var s = ApprovalDetailState(key: "device:approval.pending:h1")
        s.approval = .device(request(h))
        s.heldItems = items
        s.itemsLoaded = loaded
        return s
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private var all: [HeldApproval] {
        [
            .itemUse(itemID: "i1", fieldID: "f2", data: Array("hello".utf8)), .itemUse(itemID: "i1", fieldID: "f2", data: [0xFF, 0x00, 0x7F]),
            .itemGet(itemID: "i1", fieldIDs: ["f1", "f2"]), .itemGet(itemID: "i1", fieldIDs: nil), .catalog, .desktopStepUp, .unshown,
            .itemUse(itemID: "i9", fieldID: "f2", data: [1]),
        ]
    }

    @Test func everyHeldRequestRenders() {
        for h in all {
            let s = state(h)
            #expect(height(ApprovalDetailScreen(state: s, actions: DecisionActions())) > 0, "\(s)")
        }
        #expect(height(ApprovalDetailScreen(state: state(.catalog, loaded: false), actions: DecisionActions())) > 0)
    }

    @Test func theDataBoxShowsTheAgentsDataUnderItsLabel() {
        let text = HeldFacts(request: request(.catalog), show: .use(item: "GitHub", field: "User", data: .text("hello"), bytes: 5), now: Date())
        let hex = HeldFacts(request: request(.catalog), show: .use(item: "GitHub", field: "User", data: .hex("ff 00"), bytes: 2), now: Date())
        let catalog = HeldFacts(request: request(.catalog), show: .catalog, now: Date())
        #expect(height(text) > height(catalog) && height(hex) > height(text), "the hex adds its line")
    }

    @Test func aRevealSaysItsFieldsAndAlwaysTheHistoryLine() {
        let some = HeldFacts(request: request(.catalog), show: .get(item: "GitHub", fields: ["Token"]), now: Date())
        let all = HeldFacts(request: request(.catalog), show: .get(item: "GitHub", fields: nil), now: Date())
        #expect(height(some) > height(HeldFacts(request: request(.catalog), show: .catalog, now: Date())) && height(all) > 0)
    }

    @Test func theRowsComeFromTheItemList() {
        var list = ApprovalsState()
        list.items = items
        list.approvals = [.device(request(.itemGet(itemID: "i1", fieldIDs: ["f1"])))]
        #expect(list.heldShow(list.approvals[0]) == .get(item: "GitHub", fields: ["Token"]))
        #expect(list.heldShow(Samples.auth()) == nil && list.heldShow(Samples.device("device.session.pending")) == nil)
        list.itemsLoaded = false
        list.items = []
        #expect(list.heldShow(list.approvals[0]) == .noItem(use: false, loading: true))
        let row = ApprovalRow(approval: list.approvals[0], name: nil, held: list.heldShow(list.approvals[0]), onOpen: { _ in })
        #expect(height(row) > 0)
    }

    @Test func eachAnswerRenders() {
        for o in [DeviceOutcome.denied, .noLongerWaiting, .referred, .approved(result: "ok"), .approved(result: nil), .approved(result: "forbidden"), .approved(result: "x")] {
            var s = state(.catalog)
            s.outcome = o
            #expect(height(ApprovalDetailScreen(state: s, actions: DecisionActions())) > 0, "\(o)")
        }
    }

    /// Approve is not offered where the app cannot approve; Deny stays.
    @Test func approveIsOfferedOnlyWhereTheAppCanApprove() {
        #expect(state(.catalog).canApprove() && state(.itemGet(itemID: "i1", fieldIDs: ["f1"])).canApprove())
        #expect(!state(.unshown).canApprove() && !state(.desktopStepUp).canApprove() && !state(.itemUse(itemID: "i9", fieldID: "f1", data: [1])).canApprove())
        #expect(!state(.catalog, loaded: false).canApprove())
    }

    // MARK: - A run and a proxy (AA8)

    private let sha = String(repeating: "1a2b3c4d5e6f7a8b", count: 4)

    private func runState(argv: [String], flags: Set<RunFlag> = [], replaces: String? = nil) -> ApprovalDetailState {
        let r = ItemRun(itemID: "i1", fieldID: "f1", program: argv[0], sha256: sha, argv: argv, cwd: nil, how: .env, name: "T", env: [], flags: flags, previousSha256: nil, previousPath: nil, replaces: replaces)
        return state(.itemRun(r))
    }

    @Test func aRunAProxyAndAnExpiredOneRender() {
        for s in [runState(argv: ["/usr/bin/git", "push"]), runState(argv: ["/usr/bin/git"], flags: [.shell, .programUnrecorded], replaces: "h0"),
                  state(.itemProxy(ItemProxy(itemID: "i1", fieldID: "f1", host: "api.example.com", header: "Authorization", prefix: "Bearer ", seconds: 90, replaces: nil)))] {
            #expect(height(ApprovalDetailScreen(state: s, actions: DecisionActions())) > 0)
        }
        let s = runState(argv: ["/usr/bin/git"])
        guard case .device(let d)? = s.approval, let show = s.heldShow else { Issue.record("no request"); return }
        #expect(height(AgentWayScreen(state: s, request: d, show: show, actions: DecisionActions(), now: Date(), expired: true)) > 0)
    }

    @Test func aRunsAnswerAndItsPinRender() {
        for o in [DeviceOutcome.approved(result: "ok", way: .run, pinRecorded: true, item: "GitHub"), .approved(result: "cwd_not_allowed", way: .run), .referred] {
            var s = runState(argv: ["/usr/bin/git"])
            s.outcome = o
            #expect(height(ApprovalDetailScreen(state: s, actions: DecisionActions())) > 0, "\(o)")
        }
    }

    // MARK: The gate on screen

    /// The screen in a window, laid out; each of [scrollTo] ("end", "top") applied in turn; whether the gate says reached before
    /// and after each.
    private func gateStates(_ s: ApprovalDetailState, scrollTo: [String]) async -> [Bool] {
        guard case .device(let d)? = s.approval, let show = s.heldShow else { return [] }
        let seen = Seen()
        var screen = AgentWayScreen(state: s, request: d, show: show, actions: DecisionActions(), now: Date())
        screen.onGate = { seen.reached = $0 }
        let host = UIHostingController(rootView: screen.vettIDTheme(.light))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        var out: [Bool] = []
        for step in [""] + scrollTo {
            if let scroll = Self.scrollView(in: host.view) {
                switch step {
                case "end": scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
                case "top": scroll.setContentOffset(.zero, animated: false)
                default: break
                }
            }
            for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(25)) }
            out.append(seen.reached)
        }
        return out
    }

    private final class Seen { var reached = false }

    private static func scrollView(in v: UIView) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, s.contentSize.height > 0 { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(v)
        // The scrolled content is the tallest scroll view (the button panel's lines are another, short one).
        return found.max { $0.contentSize.height < $1.contentSize.height }
    }

    @Test func approveWaitsForTheEndOfALongRunAndStaysEnabledScrollingBack() async {
        let long = ["/usr/bin/git"] + (1...64).map { "arg-\($0)-" + String(repeating: "x", count: 500) }
        let states = await gateStates(runState(argv: long), scrollTo: ["end", "top"])
        #expect(states == [false, true, true], "disabled, then the end, then back up: still reached \(states)")
    }

    @Test func aShortRunThatFitsIsReachedAtOnce() async {
        let states = await gateStates(runState(argv: ["/usr/bin/git"]), scrollTo: [])
        #expect(states == [true], "\(states)")
    }
}

// swiftlint:enable line_length
#endif
