import Foundation
@testable import VettIDData
import VettIDVotes

/// Votes as the vault shows them, for the screen tests.
enum Samples {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let key = VoteKey(connectionID: "c1", proposalID: "p1")

    static func open(
        ballot: VoteBallot? = nil, canCast: Bool = true, confirmPending: Bool = false, state: VoteState = .open,
        check: VoteCheck? = nil, cannotCast: String? = nil, reason: String? = nil
    ) -> VoteSummary {
        VoteSummary(
            proposalID: "p1", connectionID: "c1", title: "Budget 2027", state: state, reason: reason, opensAt: t0,
            closesAt: t0.addingTimeInterval(86_400), ballot: ballot, check: check, confirmPending: confirmPending, canCast: canCast,
            cannotCast: cannotCast
        )
    }

    static func closed(_ ballot: VoteBallot?, check: VoteCheck? = nil, conflict: Bool = false) -> VoteSummary {
        VoteSummary(
            proposalID: "p1", connectionID: "c1", title: "Budget 2027", state: .closed, closesAt: t0, ballot: ballot, check: check,
            conflictEvidence: conflict
        )
    }

    static let choices = [VoteChoice(id: "yes", label: "Yes"), VoteChoice(id: "no", label: "No"), VoteChoice(id: "abstain", label: "Abstain")]

    static func detail(
        _ s: VoteSummary, choiceID: String? = nil, serviceBallot: String? = nil, tally: [String: Int64]? = nil, counts: VoteCounts? = nil
    ) -> VoteDetail {
        VoteDetail(
            summary: s, text: "The board proposes the budget.\nSecond line.", choices: choices, quorumText: "A third of the members",
            minBallots: 2, binding: true, choiceID: choiceID, tally: tally, counts: counts, serviceBallotChoiceID: serviceBallot
        )
    }

    /// A state of the vote screen.
    static func screen(_ s: VoteSummary?, detail: VoteDetail? = nil, _ change: (inout VoteScreenState) -> Void = { _ in }) -> VoteScreenState {
        var st = VoteScreenState(key: key)
        st.summary = s
        st.detail = detail ?? s.map(plain)
        st.serviceName = "Example Org"
        st.loaded = true
        change(&st)
        return st
    }

    private static func plain(_ s: VoteSummary) -> VoteDetail { VoteDetail(summary: s, text: "T", choices: choices) }
}
