import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVotes

/// The published results checked again when a vote's screen opens (owner decision 2026-11-02).
extension VoteViewModelTests {
    /// A closed vote whose check is [check], with a tally, opened after a lock (the repository holds no hint).
    func verifiedScreen(_ check: CheckState = .verified, outcome: RecheckOutcome) async -> VoteViewModel {
        let s = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: check))
        fake.votes = [s]
        var d = Samples.detail(s, choiceID: "yes")
        d.tally = ["yes": 3, "no": 1]
        d.counts = VoteCounts(eligible: 9, ballots: 4, unhandled: 0)
        fake.details[s.key] = d
        fake.hints = [:]
        fake.recheckOutcome = outcome
        let m = VoteViewModel(key: s.key, repo: fake, connections: connections, now: { Samples.t0 })
        await m.settle()
        return m
    }

    var rechecks: Int { fake.calls.filter { $0 == "recheckResults:c1/p1" }.count }

    @Test func afterALockOpeningTheVoteChecksItsResultsAgainAndHidesNumbersThatDontAddUp() async {
        let m = await verifiedScreen(outcome: .dontAddUp)
        #expect(rechecks == 1 && !fake.calls.contains { $0.hasPrefix("checkResults") })
        let f = Samples.facts(m.state)
        #expect(f.results == nil && f.notes.map(\.note).suffix(2) == [.inResults, .resultsDontAddUp])
        // One check an opening: Try again does not repeat it.
        m.refresh()
        await m.settle()
        #expect(rechecks == 1)
    }

    @Test func goodResultsShowTheirNumbers() async {
        let m = await verifiedScreen(.unconfirmed, outcome: .consistent)
        #expect(rechecks == 1 && m.state.recheck == .done)
        let f = Samples.facts(m.state)
        #expect(f.results?.first == "Results" && !f.notes.map(\.note).contains(.resultsNotRechecked))
    }

    @Test func aSiteThatCantBeReachedHidesTheNumbersAndSaysSo() async {
        let m = await verifiedScreen(outcome: .notChecked)
        let f = Samples.facts(m.state)
        #expect(f.results == nil && f.notes.map(\.note).suffix(2) == [.inResults, .resultsNotRechecked])
        #expect(f.notes.last?.text == VoteStrings.voteResultsNotRechecked)
    }

    @Test func aRecheckCutOffSaysNothingKeepsTheNumbersHiddenAndRunsWhenTheScreenComesBack() async {
        fake.failError["recheckResults:c1/p1"] = CancellationError()
        let m = await verifiedScreen(outcome: .consistent)
        #expect(m.state.recheck == .running && m.state.loadError == nil && m.state.checkProblem == nil)
        #expect(Samples.facts(m.state).results == nil)
        m.leave()
        m.appeared()
        await m.settle()
        #expect(rechecks == 2 && m.state.recheck == .done && Samples.facts(m.state).results != nil)
    }

    /// The screen left and came back at once while a check was under way: the old check's cancellation, arriving after the
    /// new one started, does not let a third one start.
    @Test func anOldChecksCancellationDoesNotStartAThird() async {
        let s = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified))
        fake.votes = [s]
        fake.details[s.key] = Samples.detail(s, choiceID: "yes")
        fake.recheckOutcome = .consistent
        fake.recheckHold = { try await Task.sleep(for: .seconds(30)) }
        let m = VoteViewModel(key: s.key, repo: fake, connections: connections, now: { Samples.t0 })
        for _ in 0..<50 { await Task.yield() }
        #expect(rechecks == 1 && m.state.recheck == .running)
        m.leave()
        m.appeared()
        await m.settle()
        #expect(rechecks == 2 && m.state.recheck == .done)
        m.appeared()
        await m.settle()
        #expect(rechecks == 2)
    }

    /// A lock and unlock with the screen up forget the verdict: the results are checked again once the vote is back.
    @Test func aLockAndUnlockWithTheScreenUpChecksAgain() async {
        let m = await verifiedScreen(outcome: .consistent)
        #expect(rechecks == 1 && Samples.facts(m.state).results != nil)
        let listed = fake.votes
        fake.hints = [:]
        fake.votes = []
        await m.settle()
        #expect(Samples.facts(m.state).results == nil)
        fake.recheckOutcome = .dontAddUp
        fake.votes = listed
        await m.settle()
        #expect(rechecks == 2)
        let f = Samples.facts(m.state)
        #expect(f.results == nil && f.notes.map(\.note).contains(.resultsDontAddUp))
    }

    /// The app went to the background during the check (the work was halted): it runs again when the app returns to the
    /// foreground, with the screen still up.
    @Test func aRecheckCutOffByTheBackgroundRunsAgainInTheForeground() async {
        fake.failError["recheckResults:c1/p1"] = CancellationError()
        let m = await verifiedScreen(outcome: .dontAddUp)
        #expect(m.state.recheck == .running && rechecks == 1)
        // The screen's foreground action (no onAppear fires on a return from the background).
        m.appeared()
        await m.settle()
        #expect(rechecks == 2 && m.state.recheck == .done)
        let f = Samples.facts(m.state)
        #expect(f.results == nil && f.notes.map(\.note).suffix(2) == [.inResults, .resultsDontAddUp])
        // Done: another return checks nothing again.
        m.appeared()
        await m.settle()
        #expect(rechecks == 2)
    }

    /// Results found not to add up stay hidden on an unconfirmed vote when **Check again** then submits nothing (the site
    /// down clears the attempt's flag, not the check's verdict).
    @Test func numbersFoundNotToAddUpStayHiddenAfterACheckAgainThatSubmitsNothing() async {
        let m = await verifiedScreen(.unconfirmed, outcome: .dontAddUp)
        fake.resultsOutcome = .siteUnreachable
        fake.onCheckResults = { fake in fake.hints[Samples.key]?.resultsDontAddUp = false }
        m.checkWithService()
        await m.settle()
        #expect(fake.hints[Samples.key]?.resultsDontAddUp == false)
        let f = Samples.facts(m.state)
        #expect(f.results == nil && f.notes.map(\.note).contains(.resultsDontAddUp))
    }

    @Test func anOpenOrPendingVoteIsNotCheckedAgain() async {
        _ = await screen()
        _ = await screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending)))
        #expect(rechecks == 0)
    }
}
