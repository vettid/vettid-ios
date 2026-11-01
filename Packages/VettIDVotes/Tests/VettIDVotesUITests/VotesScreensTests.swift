#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDData
import VettIDUI
@testable import VettIDVotes
@testable import VettIDVotesUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Votes screens (ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes"; IOS-PLAN §4.16): every state of the list and of a vote
/// rendered, the unlock window notice on both screens, the dropped notice acknowledged, the vote kept out of captures, the
/// secrets dropped when the screen leaves, and the proof document. What the screens say is checked, as text, in
/// `VoteFactsTests` and `VoteStringsTests` (the hosted tree gives no text without an assistive technology). Mirrors
/// vettid-android `VoteScreenTest`.
@MainActor
@Suite(.serialized) struct VotesScreensTests {
    private var chrome: ShellChrome { ShellChrome(accountName: "Ada Lovelace", onMenu: {}, onAvatar: {}) }

    private func listState(_ change: (inout VotesState) -> Void) -> VotesState {
        var s = VotesState()
        s.load = .loaded
        s.services = ["c1": "Example Org"]
        change(&s)
        return s
    }

    @Test func everyListStateRenders() {
        var loading = VotesState()
        loading.load = .loading
        let failed = listState { $0.error = .network }
        let empty = listState { _ in }
        let full = listState {
            $0.votes = [Samples.open(), Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified)), Samples.open(state: .checking)]
            $0.reconnect = [ReconnectEntry(connectionID: "c9", serviceID: "s", name: "Other")]
            $0.dropped = [DroppedNotice(connectionID: "c1", count: 2)]
            $0.problems = [ProblemsNotice(connectionID: "c1", count: 3)]
            $0.windowNotClosed = WindowNotClosed(ttlSeconds: 120)
            $0.error = .network
        }
        for s in [loading, failed, empty, full] {
            #expect(height(VotesScreen(state: s, chrome: chrome, actions: VotesActions())) > 0, "\(s)")
            #expect(height(ConnectionVotesScreen(state: s, onBack: {}, actions: VotesActions())) > 0, "\(s)")
        }
    }

    @Test func aShownDroppedNoticeIsAcknowledgedOnceTheListWasRead() {
        var acknowledged: [[String]] = []
        var actions = VotesActions()
        actions.onNoticesShown = { acknowledged.append($0) }
        var s = listState { $0.dropped = [DroppedNotice(connectionID: "c1", count: 2)]; $0.votes = [Samples.open()] }
        _ = host(VotesScreen(state: s, chrome: chrome, actions: actions))
        #expect(acknowledged == [["c1"]])
        // Not before the list was read.
        acknowledged = []
        s.load = .loading
        _ = host(VotesScreen(state: s, chrome: chrome, actions: actions))
        #expect(acknowledged.isEmpty)
    }

    /// Owner behaviour 1: the notice renders on the list and on the vote (its words are checked in `VoteFactsTests`).
    @Test func theWindowNoticeRendersOnTheListAndOnTheVote() {
        var notice = listState { $0.votes = [Samples.open()] }
        notice.windowNotClosed = WindowNotClosed(ttlSeconds: 600)
        #expect(height(VotesScreen(state: notice, chrome: chrome, actions: VotesActions())) > 0)
        var closeAsked = 0
        var actions = VotesActions()
        actions.onCloseWindow = { closeAsked += 1 }
        _ = host(VotesScreen(state: notice, chrome: chrome, actions: actions))
        var vote = Samples.screen(Samples.open())
        vote.windowNotClosed = WindowNotClosed(ttlSeconds: 90)
        #expect(facts(vote).windowNotClosed != nil && facts(Samples.screen(Samples.open())).windowNotClosed == nil)
        #expect(height(VoteContent(state: vote, facts: facts(vote), actions: VoteActions())) > 0)
        #expect(closeAsked == 0)
    }

    @Test func everyVoteStateRenders() {
        let confirm = Samples.open(confirmPending: true)
        let states: [VoteScreenState] = [
            VoteScreenState(key: Samples.key),
            Samples.screen(nil) { $0.loaded = true },
            Samples.screen(nil) { $0.loadError = VoteProblem(kind: .network) },
            Samples.screen(Samples.open()),
            Samples.screen(Samples.open()) { $0.selected = "yes" },
            Samples.screen(Samples.open(ballot: VoteBallot(state: .waiting), canCast: false)),
            Samples.screen(confirm, detail: Samples.detail(confirm, serviceBallot: "no")),
            Samples.screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified), conflict: true)),
            Samples.screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified)), detail: resultsDetail()),
            Samples.screen(Samples.closed(VoteBallot(state: .conflict), check: VoteCheck(state: .failed))) { $0.proofExported = true; $0.proofSaved = true },
            Samples.screen(Samples.open(canCast: false, state: .rejected, reason: "anchor")),
            Samples.screen(Samples.open()) { $0.castProblem = VoteProblem(kind: .noResponse); $0.alreadyVoted = true; $0.checkProblem = VoteProblem(kind: .network) },
            Samples.screen(Samples.open()) { $0.windowNotClosed = WindowNotClosed(ttlSeconds: nil); $0.windowCloseProblem = VoteProblem(kind: .network) },
            Samples.screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending))) { $0.checkOutcome = .notPublished },
        ]
        for s in states { #expect(height(VoteScreen(state: s, actions: VoteActions())) > 0, "\(s)") }
    }

    @Test func everySheetRenders() {
        let s = Samples.open()
        let confirm = Samples.open(confirmPending: true)
        let sheets: [VoteScreenState] = [
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .confirm },
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .sending },
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .password },
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .password; $0.passwordError = VoteProblem(kind: .badPassword) },
            Samples.screen(s) { $0.selected = "yes"; $0.cast = .sending; $0.password = "x" },
        ]
        for st in sheets { #expect(height(CastSheet(state: st, actions: VoteActions())) > 0, "\(st)") }
        let restore = Samples.screen(confirm, detail: Samples.detail(confirm, serviceBallot: "no"))
        #expect(height(RestoreSheet(state: restore, actions: VoteActions())) > 0)
        var busy = restore
        busy.restoreBusy = true
        busy.restoreProblem = VoteProblem(kind: .network)
        #expect(height(RestoreSheet(state: busy, actions: VoteActions())) > 0)
        let release = Samples.screen(Samples.closed(VoteBallot(state: .conflict))) { $0.proofExported = true; $0.releaseDialog = true }
        #expect(height(ReleaseSheet(state: release, actions: VoteActions())) > 0)
        var refused = release
        refused.releaseProblem = VoteProblem(kind: .other, code: "evidence_not_exported")
        #expect(height(ReleaseSheet(state: refused, actions: VoteActions())) > height(ReleaseSheet(state: release, actions: VoteActions())))
    }

    /// The release sheet's PIN is on the in-app keypad (IOS-PLAN §6.5): no text field, so no keyboard sees it.
    @Test func theReleasePinHasNoTextField() {
        let release = Samples.screen(Samples.closed(VoteBallot(state: .conflict))) { $0.proofExported = true; $0.releaseDialog = true }
        let window = host(ReleaseSheet(state: release, actions: VoteActions()))
        #expect(!views(in: window).contains { $0 is UITextField })
    }

    /// The credential password is on the secret field of IOS-PLAN §6.5: a masked field with no AutoFill.
    @Test func thePasswordIsOnTheSecretField() {
        let st = Samples.screen(Samples.open()) { $0.cast = .password; $0.password = "x" }
        let window = host(CastSheet(state: st, actions: VoteActions()))
        let fields = views(in: window).compactMap { $0 as? UITextField }
        #expect(!fields.isEmpty && fields.allSatisfy { $0.isSecureTextEntry && $0.autocorrectionType == .no })
        #expect(fields.allSatisfy { $0.textContentType?.rawValue == "" })
    }

    @Test func theProofDocumentIsTheEvidenceUnchanged() {
        let text = #"{"evidence":{"choice_id":"yes","sig":"AbC=="}}"#
        let doc = ProofDocument(ProofFile(bytes: Data(text.utf8), name: "vettid-vote-p1.json"))
        #expect(doc.bytes == Data(text.utf8) && ProofDocument.readableContentTypes == [.json])
    }

    // MARK: Capture and secrets

    /// IOS-PLAN §4.16 "Screen privacy": the vote screen and its sheets are on the secure layer, unless screenshots are allowed.
    @Test func theVoteIsKeptOutOfCaptures() {
        guard SecureLayer.isAvailable else { return }
        let screen = VoteScreen(state: Samples.screen(Samples.open()), actions: VoteActions())
        let protected = host(screen.environment(ScreenshotAllowance(onByDefault: false)))
        let allowed = host(screen.environment(ScreenshotAllowance(onByDefault: true)))
        #expect(views(in: protected).contains(where: onSecureLayer))
        #expect(views(in: protected).filter(onSecureLayer).count > views(in: allowed).filter(onSecureLayer).count)
        for sheet in [
            host(CastSheet(state: Samples.screen(Samples.open()) { $0.cast = .confirm }, actions: VoteActions())),
            host(CastSheet(state: Samples.screen(Samples.open()) { $0.cast = .password }, actions: VoteActions())),
            host(ReleaseSheet(state: Samples.screen(Samples.closed(VoteBallot(state: .conflict))), actions: VoteActions())),
        ] { #expect(views(in: sheet).contains(where: onSecureLayer)) }
    }

    @Test func leavingTheScreenAsksTheModelToForgetThePasswordAndUnsavedEvidence() {
        var left = 0
        var actions = VoteActions()
        actions.onLeave = { left += 1 }
        var window: UIWindow? = host(VoteScreen(state: Samples.screen(Samples.open()), actions: actions))
        window?.rootViewController = nil
        window = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(left >= 1)
    }

    // MARK: Helpers

    private func resultsDetail() -> VoteDetail {
        var d = Samples.detail(Samples.closed(VoteBallot(state: .recorded)), choiceID: "yes")
        d.tally = ["yes": 3, "no": 1]
        d.counts = VoteCounts(eligible: 9, ballots: 4, unhandled: 2)
        return d
    }

    private func facts(_ s: VoteScreenState) -> VoteFacts { VoteFacts.of(s, summary: s.summary ?? Samples.open(), now: Samples.t0) }

    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view.vettIDTheme())
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    private func views(in view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views(in: $0) } }

    private func onSecureLayer(_ v: UIView) -> Bool { String(describing: type(of: v)).contains("Canvas") }
}
// swiftlint:enable line_length
#endif
