import Foundation
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVotes

/// Votes as the vault shows them, for the tests.
enum Samples {
    static let key = VoteKey(connectionID: "c1", proposalID: "p1")
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// An open vote the member may cast.
    static func open(
        _ c: String = "c1", _ p: String = "p1", title: String = "Budget 2027", ballot: VoteBallot? = nil, canCast: Bool = true,
        confirmPending: Bool = false, state: VoteState = .open, check: VoteCheck? = nil, cannotCast: String? = nil,
        reason: String? = nil
    ) -> VoteSummary {
        VoteSummary(
            proposalID: p, connectionID: c, title: title, state: state, reason: reason, opensAt: t0,
            closesAt: t0.addingTimeInterval(86_400),
            ballot: ballot, check: check, confirmPending: confirmPending, canCast: canCast, cannotCast: cannotCast
        )
    }

    static func closed(_ ballot: VoteBallot? = nil, check: VoteCheck? = nil, conflict: Bool = false) -> VoteSummary {
        VoteSummary(
            proposalID: "p1", connectionID: "c1", title: "Budget 2027", state: .closed, closesAt: t0, ballot: ballot, check: check,
            conflictEvidence: conflict
        )
    }

    static let choices = [
        VoteChoice(id: "yes", label: "Yes"), VoteChoice(id: "no", label: "No"), VoteChoice(id: "abstain", label: "Abstain"),
    ]

    static func detail(_ s: VoteSummary, choiceID: String? = nil, serviceBallot: String? = nil) -> VoteDetail {
        VoteDetail(
            summary: s, text: "The board proposes the budget.", choices: choices, choiceID: choiceID, serviceBallotChoiceID: serviceBallot
        )
    }

    /// A state of the vote screen over [s].
    static func screen(
        _ s: VoteSummary, detail: VoteDetail? = nil, _ change: (inout VoteScreenState) -> Void = { _ in }
    ) -> VoteScreenState {
        var st = VoteScreenState(key: s.key)
        st.summary = s
        st.detail = detail ?? Samples.detail(s)
        st.serviceName = "Example Org"
        st.loaded = true
        change(&st)
        return st
    }

    static func facts(_ st: VoteScreenState, now: Date = t0) -> VoteFacts {
        VoteFacts.of(st, summary: st.summary ?? open(), now: now)
    }

    static func service(_ id: String = "c1", name: String = "Example Org") -> ConnectionInfo {
        var c = ConnectionInfo(id: id, name: name, state: .active)
        c.isService = true
        return c
    }
}
