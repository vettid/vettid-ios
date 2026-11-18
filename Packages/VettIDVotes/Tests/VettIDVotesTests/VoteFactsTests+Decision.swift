import Foundation
import Testing
@testable import VettIDData
@testable import VettIDVotes

// Expected texts stay on one line each.
// swiftlint:disable line_length

/// How a vote is decided, shown before the member votes, and its outcome at the top of the results (BALLOT-PROTOCOL 0.14.0
/// §3.5, §7.1; VAULT-MESSAGING 0.90.18 §10.19.8: both from the vault's own `vote.get`).
extension VoteFactsTests {
    func rule(_ rule: VoteDecision.Rule, _ base: VoteDecision.Base?) -> String? {
        let s = Samples.open()
        var d = Samples.detail(s)
        d.decision = VoteDecision(rule: rule, base: base)
        return Samples.facts(Samples.screen(s, detail: d)).rule
    }

    @Test func theRuleIsShownInTheOwnersWordsForEachRuleAndBase() {
        #expect(rule(.majority, .cast) == "Decided by more than half of the votes for a choice. Abstaining doesn't count.")
        #expect(rule(.majority, .voted) == "Decided by more than half of all ballots. Abstaining counts against.")
        #expect(rule(.majority, .elig) == "Decided by more than half of all eligible members. Not voting counts against.")
        #expect(rule(.threshold(num: 2, den: 3), .cast) == "Decided by at least 2/3 of the votes for a choice. Abstaining doesn't count.")
        #expect(rule(.threshold(num: 3, den: 4), .voted) == "Decided by at least 3/4 of all ballots. Abstaining counts against.")
        #expect(rule(.threshold(num: 9, den: 10), .elig) == "Decided by at least 9/10 of all eligible members. Not voting counts against.")
        #expect(rule(.threshold(num: 1, den: 1), .cast) == "Decided only if every vote for a choice is for the same one. Abstaining doesn't count.")
        #expect(rule(.threshold(num: 1, den: 1), .voted) == "Decided only if all ballots are for one choice. Abstaining counts against.")
        #expect(rule(.threshold(num: 1, den: 1), .elig) == "Decided only if all eligible members vote for one choice. Not voting counts against.")
        #expect(rule(.plurality, nil) == "Decided by the most votes. A tie at the top decides nothing.")
    }

    @Test func noRuleLineWithoutADecisionOrForAMajorityWithoutABase() {
        let s = Samples.open()
        #expect(Samples.facts(Samples.screen(s)).rule == nil)
        #expect(rule(.majority, nil) == nil && rule(.threshold(num: 2, den: 3), nil) == nil)
    }

    func results(_ outcome: VoteOutcome?, observed: Bool? = true) -> [String]? {
        let s = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified))
        var d = Samples.detail(s, choiceID: "yes")
        d.tally = ["yes": 3, "no": 1, "abstain": 0]
        d.counts = VoteCounts(eligible: 9, ballots: 4, unhandled: 2)
        d.outcome = outcome
        return Samples.facts(Samples.screen(s, detail: d) { $0.hint = VoteHint(observerVerdict: observed) }).results
    }

    @Test func theOutcomeIsTheFirstResultsLineAndTheUnhandledLineStaysAtTheEnd() throws {
        let r = try #require(results(VoteOutcome(status: .decided, choice: "yes")))
        #expect(Array(r.prefix(2)) == ["Results", "Decided: \u{2068}Yes\u{2069}"])
        #expect(r.last == "2 messages sent to \u{2068}Example Org\u{2069} during the vote were not handled; any vote among them was not counted.")
        #expect(results(VoteOutcome(status: .notDecided, choice: nil))?[1] == "Not decided: no choice met the rule.")
        #expect(results(VoteOutcome(status: .tied, choice: nil))?[1] == "Tied: no choice decided.")
        #expect(results(VoteOutcome(status: .noQuorum, choice: nil))?[1] == "No quorum: too few members voted.")
        #expect(results(nil)?[1] == "\u{2068}Yes\u{2069}: 3", "no outcome line without one")
    }

    /// `decided` shows only a real choice of the vote: never abstain, never an id the vote doesn't have.
    @Test func aDecidedChoiceThatIsNotARealChoiceShowsNoLine() {
        #expect(results(VoteOutcome(status: .decided, choice: "abstain"))?[1] == "\u{2068}Yes\u{2069}: 3")
        #expect(results(VoteOutcome(status: .decided, choice: "maybe"))?[1] == "\u{2068}Yes\u{2069}: 3")
    }

    /// The lines under the proposal, in order: the quorum, then how it's decided, then whether it's binding.
    @Test func theRuleSitsBetweenTheQuorumAndBinding() {
        let s = Samples.open()
        var d = Samples.detail(s)
        d.quorumText = "Half"
        d.binding = true
        d.decision = VoteDecision(rule: .plurality, base: nil)
        #expect(Samples.facts(Samples.screen(s, detail: d)).facts == [
            "Quorum, as the service states it: \u{2068}Half\u{2069}", "Decided by the most votes. A tie at the top decides nothing.",
            "The service says this vote is binding.",
        ])
    }

    /// The outcome is one of the numbers (VAULT-MESSAGING 0.90.18 §10.19.6 step 1): hidden with them when the app's own
    /// observer check failed or hasn't run.
    @Test func theOutcomeIsHiddenWithTheNumbers() {
        #expect(results(VoteOutcome(status: .decided, choice: "yes"), observed: false) == nil)
        #expect(results(VoteOutcome(status: .decided, choice: "yes"), observed: nil) == nil)
    }
}

// swiftlint:enable line_length
