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

    /// A run that expired and left the list says so on its own screen, not "Already decided" (AA8 "Refused or expired").
    @Test func anExpiredRunThatLeftTheListSaysSo() {
        var s = runState(argv: ["/usr/bin/git"])
        guard case .device(var d)? = s.approval else { Issue.record("no request"); return }
        d.exp = Date().addingTimeInterval(-1)
        s.approval = .device(d)
        s.gone = true
        let screen = ApprovalDetailScreen(state: s, actions: DecisionActions())
        #expect(screen.expiredWay(at: Date()) != nil)
        #expect(height(screen) > 0)
        var decided = s
        decided.approval = .device(request(.itemRun(ItemRun(itemID: "i1", fieldID: "f1", program: "/x", sha256: sha, argv: ["/x"], cwd: nil, how: .env, name: "T", env: [], flags: [], previousSha256: nil, previousPath: nil, replaces: nil))))
        #expect(ApprovalDetailScreen(state: decided, actions: DecisionActions()).expiredWay(at: Date()) == nil, "gone but not expired: Already decided")
        decided.approval = s.approval
        decided.outcome = .denied
        #expect(ApprovalDetailScreen(state: decided, actions: DecisionActions()).expiredWay(at: Date()) == nil)
        var other = state(.catalog)
        other.gone = true
        var catalog = request(.catalog)
        catalog.exp = Date().addingTimeInterval(-1)
        other.approval = .device(catalog)
        #expect(ApprovalDetailScreen(state: other, actions: DecisionActions()).expiredWay(at: Date()) == nil, "only a run or a proxy")
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
    private func gateStates(_ s: ApprovalDetailState, scrollTo: [String], insets: Bool = false, height: CGFloat = 844) async -> [Bool] {
        guard case .device(let d)? = s.approval, let show = s.heldShow else { return [] }
        let seen = Seen()
        var screen = AgentWayScreen(state: s, request: d, show: show, actions: DecisionActions(), now: Date())
        screen.onGate = { seen.reached = $0 }
        // The app's own container: a navigation stack (its bar hidden, the screen has its own Back), in a window of a real scene
        // when the tests are hosted in the app, with the safe-area insets of a phone (a top and a bottom one) added when [insets].
        let host = UIHostingController(rootView: NavigationStack { screen.toolbar(.hidden, for: .navigationBar) }.vettIDTheme(.light))
        if insets { host.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0) }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
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

    /// Under the safe area of a phone (a top and a bottom inset), in the app's navigation container: the top marker rests at the
    /// inset, and the end clears the bottom one.
    @Test func theGateWorksWithSafeAreaInsetsInANavigationStack() async {
        let long = ["/usr/bin/git"] + (1...64).map { "arg-\($0)-" + String(repeating: "x", count: 500) }
        let states = await gateStates(runState(argv: long), scrollTo: ["end", "top"], insets: true)
        #expect(states == [false, true, true], "\(states)")
        // Content that fits (a tall window): reached at once. In a short one the same content does not fit, and is not reached.
        let fits = await gateStates(runState(argv: ["/usr/bin/git"]), scrollTo: [], insets: true, height: 1_400)
        #expect(fits == [true], "content that fits is reached at once: \(fits)")
        let cramped = await gateStates(runState(argv: ["/usr/bin/git"]), scrollTo: [], insets: true, height: 844)
        #expect(cramped == [false], "\(cramped)")
    }

    @Test func aShortRunThatFitsIsReachedAtOnce() async {
        let states = await gateStates(runState(argv: ["/usr/bin/git"]), scrollTo: [])
        #expect(states == [true], "\(states)")
    }
}

// swiftlint:enable line_length
#endif
