#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDData
@testable import VettIDUI
@testable import VettIDVotes
@testable import VettIDVotesUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Votes screens at the accessibility text sizes (IOS-PLAN ID5): the text wraps instead of being cut, the choices stay
/// targets, and every sheet, which scrolls (`vettIDGrowingSheet`), grows with the text size, so that it
/// needs to. What VoiceOver says is checked, as text, in `VoteFactsTests` and `VoteStringsTests`.
@MainActor
@Suite(.serialized) struct VotesAccessibilityTests {
    private func size(_ view: some View, type: DynamicTypeSize) -> CGSize {
        let root = view.environment(\.dynamicTypeSize, type).vettIDTheme(.light)
        return UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: 390, height: 20_000))
    }

    @Test func aRowWrapsAtTheLargestSize() {
        let vote = Samples.open(ballot: VoteBallot(state: .recorded))
        let row = VoteRow(vote: vote, serviceName: "Example Org") {}
        #expect(size(row, type: .accessibility5).height > size(row, type: .large).height * 2)
        #expect(size(row, type: .accessibility5).width <= 390)
        let chip = StatusChip(chip: .problem, text: "Your vote may not be in the results")
        #expect(size(chip, type: .accessibility5).width <= 390)
        #expect(size(chip, type: .accessibility5).height > size(chip, type: .large).height)
    }

    @Test func theChoicesStayTargetsAndWrap() throws {
        let s = Samples.open()
        let state = Samples.screen(s) { $0.selected = "yes" }
        let detail = try #require(state.detail)
        let view = ChoicesView(detail: detail, state: state) { _ in }
        #expect(size(view, type: .large).height >= Spacing.touchTarget * 3)
        #expect(size(view, type: .accessibility5).height > size(view, type: .large).height)
    }

    @Test func everySheetGrowsWithTheTextSize() {
        let s = Samples.open()
        let confirm = Samples.open(confirmPending: true)
        let cast = Samples.screen(s) { $0.selected = "yes"; $0.cast = .confirm }
        let password = Samples.screen(s) { $0.selected = "yes"; $0.cast = .password; $0.passwordError = VoteProblem(kind: .badPassword) }
        let restore = Samples.screen(confirm, detail: Samples.detail(confirm, serviceBallot: "no")) { $0.restoreProblem = VoteProblem(kind: .network) }
        let release = Samples.screen(Samples.closed(VoteBallot(state: .conflict))) { $0.proofExported = true; $0.releaseDialog = true; $0.releaseProblem = VoteProblem(kind: .other, code: "evidence_not_exported") }
        func sheet(_ name: String, _ view: (VoteScreenState) -> some View, _ st: VoteScreenState) {
            #expect(size(view(st), type: .accessibility5).height > size(view(st), type: .large).height, "\(name)")
        }
        sheet("cast", { CastSheet(state: $0, actions: VoteActions()) }, cast)
        sheet("password", { CastSheet(state: $0, actions: VoteActions()) }, password)
        sheet("restore", { RestoreSheet(state: $0, actions: VoteActions()) }, restore)
        sheet("release", { ReleaseSheet(state: $0, actions: VoteActions()) }, release)
    }

    /// A release that went through is said when its sheet is gone, so that the sheet closing does not cut it off; a sheet
    /// that is cancelled says nothing.
    @Test func aReleaseIsSaidWhenItsSheetIsGone() {
        func spoken(released: Bool) -> [String] {
            let saved = Announcer.sink
            var log: [String] = []
            Announcer.sink = { e in if case .announcement(let t, _) = e { log.append(t) } }
            defer { Announcer.sink = saved }
            let state = Samples.screen(Samples.closed(VoteBallot(state: .conflict))) { $0.proofExported = true; $0.released = released }
            VoteScreen.releaseSheetGone(state)
            return log
        }
        #expect(spoken(released: true) == [VoteStrings.voteReleased])
        #expect(spoken(released: false).isEmpty)
    }

    /// The cards of the list and the vote wrap at the largest size, their action is a target, and nothing is wider than the
    /// screen.
    @Test func theCardsWrapAndTheirActionsAreTargets() {
        let window = WindowNotClosedCard(message: VoteMessage(title: "Window", text: "The unlock window is still open for 2 minutes."), closing: false) {}
        let reconnect = ReconnectCard(name: "Example Org") {}
        let cast = CastProblemCard(message: VoteMessage(title: "Not cast", text: "The vault did not answer. Your vote was not cast."), onDismiss: {})
        for (name, grown, usual) in [
            ("window", size(window, type: .accessibility5), size(window, type: .large)),
            ("reconnect", size(reconnect, type: .accessibility5), size(reconnect, type: .large)),
            ("cast", size(cast, type: .accessibility5), size(cast, type: .large)),
        ] {
            #expect(grown.height > usual.height, "\(name)")
            #expect(grown.width <= 390, "\(name)")
        }
        #expect(size(NoticeAction(label: "Try again") {}, type: .large).height >= Spacing.touchTarget)
        #expect(size(NoticeAction(label: "Try again") {}, type: .accessibility5).height >= Spacing.touchTarget)
        let vote = Samples.screen(Samples.open()) { $0.selected = "yes" }
        let notes = VoteContent(state: vote, facts: VoteFacts.of(vote, summary: Samples.open(), now: Samples.t0), actions: VoteActions())
        // The vote scrolls: it takes the height it is offered, so nothing of it is out of reach.
        #expect(size(notes, type: .accessibility5).height == 20_000)
    }
}
// swiftlint:enable line_length
#endif
