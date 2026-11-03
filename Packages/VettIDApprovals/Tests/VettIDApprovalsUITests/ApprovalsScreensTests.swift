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

/// The Approvals screens: every state of the list and of a decision rendered (each kind of request, the gone screen, a
/// critical use's result, a backoff, the password field), the safety code and the data to sign kept out of captures, and
/// a decided request's screen closing. Mirrors vettid-android's Approvals screen tests.
@MainActor
@Suite(.serialized) struct ApprovalsScreensTests {
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

    /// A list that could not be read is never "Nothing to approve"; with rows, the failure is said above them, and an
    /// action's failure is said too.
    @Test func aFailedReadIsNotTheEmptyState() {
        var s = ApprovalsState()
        s.loading = false
        s.error = .network
        #expect(ApprovalsScreen.phase(s) == .failed)
        s.error = nil
        #expect(ApprovalsScreen.phase(s) == .empty)
        s.loading = true
        #expect(ApprovalsScreen.phase(s) == .loading)
        s.loading = false
        s.error = .network
        s.paused = [Samples.connection("c1", paused: true)]
        #expect(ApprovalsScreen.phase(s) == .rows && ApprovalsScreen.phase(s).failedAbove(failed: true))
        #expect(ApprovalsStrings.errorTitle == "Could not load approvals" && ApprovalsStrings.retry == "Try again" && ApprovalsStrings.ok == "OK")
    }

    /// A vault on hold: no "Try again" (the lists are read again once the daily check passes), and not said twice when
    /// the open asks' notice already says it.
    @Test func aVaultOnHoldOffersNoRetryAndIsSaidOnce() {
        var s = ApprovalsState()
        s.loading = false
        s.error = .ownerCheckRequired
        #expect(!ApprovalsScreen.offersRetry(.ownerCheckRequired) && ApprovalsScreen.offersRetry(.network))
        #expect(ApprovalsScreen.showsReadError(s))
        s.openAsksError = .ownerCheckRequired
        #expect(!ApprovalsScreen.showsReadError(s) && ApprovalsScreen.phase(s) == .failed)
        #expect(height(ApprovalsScreen(state: s, chrome: chrome, actions: ApprovalsActions())) > 0)
        s.openAsksError = .network
        #expect(ApprovalsScreen.showsReadError(s))
    }

    /// The failures are spoken by themselves: a read that failed with rows shown, and an action that failed.
    @Test func failuresAreAnnounced() async {
        var s = ApprovalsState()
        s.loading = false
        s.paused = [Samples.connection("c1", paused: true)]
        s.error = .vaultCode("approvals_read_test")
        s.actionError = .vaultCode("approvals_action_test")
        let read = "\(ApprovalsStrings.errorTitle). \(FailureKind.vaultCode("approvals_read_test").message)"
        let action = FailureKind.vaultCode("approvals_action_test").message
        let expected: [Announcer.Event] = [.announcement(read, .polite), .announcement(action, .assertive)]
        let spoken = await announcements(of: ApprovalsScreen(state: s, chrome: chrome, actions: ApprovalsActions()), until: expected) {
            $0.contains("approvals_")
        }
        #expect(expected.allSatisfy(spoken.contains))
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
        failed.actionError = .network
        var empty = ApprovalsState()
        empty.loading = false
        var full = ApprovalsState()
        full.loading = false
        full.busy = true
        full.error = .network
        full.actionError = .noResponse
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
        out += renewalStates()
        out += [AuthenticationPurpose.signin, .approval].map { p in
            var s = out[4]
            s.approval = Samples.auth("a\(p)", purpose: p)
            return s
        }
        var coded = out[4]
        coded.approval = Samples.auth("am", purpose: .signin, matchCode: "07")
        out.append(coded)
        out += withdrawnStates(out[4])
        return out
    }

    /// Withdrawn by its challenger (0.80.0 §10.4): the notice with the mute, the mute's confirmation, a failed mute, the
    /// mute on its way, muted.
    private func withdrawnStates(_ base: ApprovalDetailState) -> [ApprovalDetailState] {
        var withdrawn = base
        withdrawn.withdrawn = true
        var confirming = withdrawn
        confirming.connectionIsService = true
        confirming.confirmMute = true
        var failedMute = withdrawn
        failedMute.muteError = .network
        var muting = withdrawn
        muting.muting = true
        var muted = withdrawn
        muted.asksMuted = true
        return [withdrawn, confirming, failedMute, muting, muted]
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

    /// A renewal request (0.78.0 §6.8 step 3): its notice and "Deny and end access now", the confirmation, a failed end on
    /// the request and on the screen of a request that left, and the hold.
    private func renewalStates() -> [ApprovalDetailState] {
        var renewal = ApprovalDetailState(key: "device:device.session.pending:s1")
        renewal.approval = .device(DeviceRequest(type: "device.session.pending", id: "s1", deviceName: nil, role: "agent", requestType: nil, receivedAt: Samples.t0, exp: nil, deviceID: "dev1"))
        renewal.sessionEnd = Date().addingTimeInterval(3_600)
        var confirming = renewal
        confirming.confirmEnd = true
        var failed = renewal
        failed.endFailure = .network
        var goneFailed = failed
        goneFailed.gone = true
        var held = failed
        held.notHeld = true
        held.approval = nil
        held.held = true
        var checkRefused = renewal
        checkRefused.endFailure = .ownerCheckRequired
        return [renewal, confirming, failed, goneFailed, held, checkRefused]
    }

    /// A failed end says what did not happen to the device, by its name or kind; a refused daily check says why in the
    /// vault's words.
    @Test func aFailedEndSaysWhy() {
        let request = PendingApproval.device(DeviceRequest(type: "device.session.pending", id: "s1", deviceName: nil, role: "agent", requestType: nil, receivedAt: Samples.t0, exp: nil, deviceID: "dev1"))
        #expect(EndFailureNotice.message(.network, request, timeScale: 1) == "Access for an agent could not be ended. Try again.")
        let check = EndFailureNotice.message(.ownerCheckRequired, request, timeScale: 1)
        #expect(check == ApprovalTexts.failure(.ownerCheckRequired, retryUntil: nil, limit: nil, now: Date(), timeScale: 1) && check != ApprovalsStrings.endFailed("an agent"))
    }

    /// The renewal's notice says the approved words, and the decline-only line gives way to it.
    @Test func aRenewalSaysWhatADenyKeeps() {
        let request = DeviceRequest(type: "device.session.pending", id: "s1", deviceName: nil, role: "agent", requestType: nil, receivedAt: Samples.t0, exp: nil, deviceID: "dev1")
        func facts(_ renewal: Bool) -> CGFloat {
            UIHostingController(rootView: Facts(approval: .device(request), name: nil, renewal: renewal).vettIDTheme(.light))
                .sizeThatFits(in: CGSize(width: 390, height: 2000)).height
        }
        #expect(facts(true) < facts(false), "no decline-only line on a renewal")
        var s = ApprovalDetailState(key: "k")
        s.approval = .device(request)
        s.sessionEnd = Date().addingTimeInterval(3_600)
        let content = UIHostingController(rootView: RenewalNotices(state: s, actions: DecisionActions(), now: Date()).vettIDTheme(.light))
        s.sessionEnd = Date().addingTimeInterval(-1)
        let passed = UIHostingController(rootView: RenewalNotices(state: s, actions: DecisionActions(), now: Date()).vettIDTheme(.light))
        #expect(content.sizeThatFits(in: CGSize(width: 390, height: 2000)).height > passed.sizeThatFits(in: CGSize(width: 390, height: 2000)).height)
    }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    /// What [view] says to VoiceOver by itself once on screen, of the texts [mine] picks, waiting (at most 5 s) until
    /// [expected] were all said. The sink is this process's: no other suite of this bundle replaces it, and this suite is
    /// serialized; the texts are filtered all the same, since other suites' screens speak through it meanwhile.
    private func announcements(
        of view: some View, until expected: [Announcer.Event], _ mine: @escaping (String) -> Bool
    ) async -> [Announcer.Event] {
        let saved = Announcer.sink
        let log = EventLog()
        Announcer.sink = { e in if case .announcement(let t, _) = e, mine(t) { log.events.append(e) } }
        defer { Announcer.sink = saved }
        let window = host(view)
        defer { window.isHidden = true }
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !expected.allSatisfy(log.events.contains), ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return log.events
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
/// The events a test's sink records.
@MainActor
private final class EventLog {
    var events: [Announcer.Event] = []
}
// swiftlint:enable line_length
#endif
