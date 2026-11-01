import Foundation
import Testing
@testable import VettIDData
@testable import VettIDVotes

// Fixtures and expected texts stay on one line each.
// swiftlint:disable line_length file_length

/// What a vote screen and a list row say and offer (``VoteFacts``, ``VoteRowFacts``): ANDROID-PLAN 0.1.102 to 0.1.108 §4
/// "Votes", screens 1 to 7. Mirrors vettid-android `VoteScreenTest`'s reads of the screen's words.
@Suite struct VoteFactsTests {
    private let service = "\u{2068}Example Org\u{2069}"
    private func texts(_ f: VoteFacts) -> [String] { f.notes.map(\.text) }

    // MARK: The list

    @Test func aRowIsTheTitleTheServiceWithItsLabelATimeAndAChipInWords() {
        let open = VoteRowFacts.of(Samples.open(), serviceName: "Example Org")
        #expect(open.title == "\u{2068}Budget 2027\u{2069}" && open.chipText == "Not voted yet" && open.chip == .notVoted)
        #expect(open.supporting?.hasPrefix("\(service) · Service · Closes ") == true)
        #expect(open.spoken.hasPrefix("\u{2068}Budget 2027\u{2069}, from the service \(service), Not voted yet, Closes "))
        let upcoming = VoteRowFacts.of(Samples.open(canCast: false, state: .upcoming), serviceName: "Example Org")
        #expect(upcoming.supporting?.contains("Opens ") == true)
        let closed = VoteRowFacts.of(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified)), serviceName: "")
        #expect(closed.chipText == "Results are out" && closed.supporting?.hasPrefix("Closed ") == true)
        // A service whose name is unknown is not named.
        #expect(!closed.spoken.contains("Service") || closed.spoken.contains("from the service ,"))
        let problem = VoteRowFacts.of(Samples.closed(VoteBallot(state: .conflict)), serviceName: "S")
        #expect(problem.chip == .problem && problem.chipText == "Needs your attention")
        // A title that shows nothing reads as "Votes".
        #expect(VoteRowFacts.of(Samples.open(title: "\u{200B}"), serviceName: "S").title == "Votes")
    }

    // MARK: The proposal

    @Test func theServicesWordsAreShownAsPlainTextWithTheFixedLabels() {
        let f = Samples.facts(Samples.screen(Samples.open()))
        #expect(f.title == "\u{2068}Budget 2027\u{2069}" && f.serviceLine == "\(service) · Service" && f.serviceNote == "Name given by the service")
        #expect(f.proposalText == "The board proposes the budget." && f.writtenBy == "Written by \(service)")
        #expect(f.binding == nil && f.quorum == nil, "the sample states neither")
        #expect(f.closes?.hasPrefix("Closes ") == true)
        #expect(f.choices == ["\u{2068}Yes\u{2069}", "\u{2068}No\u{2069}", "\u{2068}Abstain\u{2069}"], "in the order sent, abstain as sent")
        #expect(f.choosing && !f.castEnabled)
    }

    @Test func quorumAndBindingAreTheServicesOwnWordsAsItStatesThem() {
        let s = Samples.open()
        var d = Samples.detail(s)
        d.quorumText = "A third of the members"
        d.binding = false
        d.extensions = 1
        let f = Samples.facts(Samples.screen(s, detail: d))
        #expect(f.quorum == "Quorum, as the service states it: \u{2068}A third of the members\u{2069}")
        #expect(f.binding == "The service says this vote is not binding.")
        #expect(f.extended?.hasPrefix("The closing time was extended to ") == true)
        d.binding = true
        #expect(Samples.facts(Samples.screen(s, detail: d)).binding == "The service says this vote is binding.")
    }

    @Test func aTextWithMarkupAndControlCharactersIsAlreadyCleanAndShownAsIs() {
        // The data layer cleans the service's words (VoteWire); the screen shows them as they are, never as markup.
        let s = Samples.open()
        var d = Samples.detail(s)
        d.text = "**Bold** <b>x</b> [link](https://example.org)"
        #expect(Samples.facts(Samples.screen(s, detail: d)).proposalText == "**Bold** <b>x</b> [link](https://example.org)")
    }

    // MARK: Casting

    @Test func castIsEnabledOnlyWithAChoiceAndTheVaultsYes() {
        let s = Samples.open()
        #expect(!Samples.facts(Samples.screen(s)).castEnabled)
        #expect(Samples.facts(Samples.screen(s) { $0.selected = "yes" }).castEnabled)
        #expect(!Samples.facts(Samples.screen(Samples.open(canCast: false, cannotCast: "closing")) { $0.selected = "yes" }).castEnabled)
        let voted = Samples.facts(Samples.screen(Samples.open(ballot: VoteBallot(state: .recorded), canCast: false)))
        #expect(!voted.choosing)
    }

    /// Owner behaviour 2: no cast while a restore waits, and the reason is written where the button would be.
    @Test func noCastWhileARestoreWaitsAndTheReasonIsWritten() {
        let s = Samples.open(confirmPending: true)
        let f = Samples.facts(Samples.screen(s, detail: Samples.detail(s, serviceBallot: "no")) { $0.selected = "yes" })
        #expect(!f.castEnabled && f.choosing)
        #expect(texts(f).contains("VettID is asking \(service) what it recorded for you before you can vote."))
    }

    @Test func eachCannotCastCodeIsWrittenWhereTheButtonIs() {
        func reason(_ code: String) -> [String] {
            texts(Samples.facts(Samples.screen(Samples.open(canCast: false, cannotCast: code))))
        }
        #expect(reason("closing") == ["This vote closes in less than 2 minutes. It is too late to cast your vote from this phone."])
        #expect(reason("connection_unavailable") == ["You are no longer connected to \(service), so you can't vote."])
        #expect(reason("not_signed_in") == ["Before you can vote, sign in to \(service) once with VettID. This lets \(service) check that your vote is yours."])
        #expect(reason("something_new") == ["You can't vote in this one right now."])
        #expect(reason("site_mismatch").first?.hasPrefix("The vote you received differs from the one published on the public site") == true)
        #expect(reason("not_open").first?.hasPrefix("This vote opens ") == true)
    }

    @Test func aCheckingVoteSaysVettIdWillTryAgainForTheClockAndOffersNoCast() {
        let s = Samples.open(canCast: false, state: .checking)
        var clock = s
        clock.reason = "clock"
        let f = Samples.facts(Samples.screen(clock))
        #expect(texts(f) == ["VettID can't finish checking this vote yet because of a time check on VettID's side. It will try again."])
        #expect(!f.castEnabled)
    }

    /// Owner behaviour 2: no answer says the vote may have been sent, and the only action of the card is to put it away
    /// (``VoteActions`` has no "send again").
    @Test func noAnswerSaysTheVoteMayHaveBeenSentAndHasNoRetry() {
        let f = Samples.facts(Samples.screen(Samples.open()) { $0.castProblem = VoteProblem(kind: .noResponse) })
        #expect(f.castProblem?.title == "VettID got no answer")
        #expect(f.castProblem?.text == "Your vote may have been sent. This screen shows it as sent once VettID knows. If it does not, you can cast again. If your first vote did arrive, it is the one that counts: a vote can't be changed.")
        let net = Samples.facts(Samples.screen(Samples.open()) { $0.castProblem = VoteProblem(kind: .network) })
        #expect(net.castProblem?.title == "VettID got no answer")
        let refused = Samples.facts(Samples.screen(Samples.open()) { $0.castProblem = VoteProblem(kind: .other, code: "closing") })
        #expect(refused.castProblem?.title == "Your vote was not sent")
        #expect(refused.castProblem?.text == "This vote closes in less than 2 minutes. It is too late to cast your vote from this phone.")
        let other = Samples.facts(Samples.screen(Samples.open()) { $0.castProblem = VoteProblem(kind: .other, code: "weird") })
        #expect(other.castProblem?.title == "Your vote was not sent" && other.castProblem?.text == FailureKind.other.message(timeScale: 1))
    }

    @Test func alreadyVotedIsNeverSilentAndNamesTheChoiceWhenKnown() {
        let s = Samples.open(ballot: VoteBallot(state: .recorded), canCast: false)
        let known = Samples.facts(Samples.screen(s, detail: Samples.detail(s, choiceID: "no")) { $0.alreadyVoted = true })
        #expect(known.alreadyVoted == "You had already voted: \u{2068}No\u{2069}. Your vote can't be changed.")
        #expect(Samples.facts(Samples.screen(Samples.open()) { $0.alreadyVoted = true }).alreadyVoted == "You had already voted. Your vote can't be changed.")
        #expect(Samples.facts(Samples.screen(Samples.open())).alreadyVoted == nil)
    }

    // MARK: The window notice (owner behaviour 1)

    @Test func theWindowNoticeNamesTheUnlockTimeAndIsTold() {
        let f = Samples.facts(Samples.screen(Samples.open()) { $0.windowNotClosed = WindowNotClosed(ttlSeconds: 90) })
        #expect(f.windowNotClosed?.title == "The unlock window may still be open")
        #expect(f.windowNotClosed?.text == "VettID could not close the credential unlock window after your vote. It closes by itself once it has not been used for 2 minutes.")
        let plain = Samples.facts(Samples.screen(Samples.open()) { $0.windowNotClosed = WindowNotClosed(ttlSeconds: nil) })
        #expect(plain.windowNotClosed?.text == "VettID could not close the credential unlock window after your vote. It closes by itself.")
        let failed = Samples.facts(Samples.screen(Samples.open()) { $0.windowNotClosed = WindowNotClosed(ttlSeconds: 60); $0.windowCloseProblem = VoteProblem(kind: .network) })
        #expect(failed.windowNotClosed?.text.hasSuffix("for 1 minute.\n" + FailureKind.network.message(timeScale: 1)) == true)
        #expect(Samples.facts(Samples.screen(Samples.open())).windowNotClosed == nil)
    }

    // MARK: States in words

    @Test func aWaitingBallotNeverSaysFailedAndOffersToCheckWithTheService() {
        let f = Samples.facts(Samples.screen(Samples.open(ballot: VoteBallot(state: .waiting), canCast: false)))
        #expect(texts(f) == ["Waiting for \(service) to confirm. Your vote is saved on your vault and is sent again until \(service) answers."])
        #expect(f.checkWithService && !f.checkAgain && !f.saveProof)
    }

    @Test func aRecordedBallotShowsTheServiceAndTheMembersOwnChoiceNeverResultsBeforeTheCheck() {
        let s = Samples.open(ballot: VoteBallot(state: .recorded), canCast: false)
        let f = Samples.facts(Samples.screen(s, detail: Samples.detail(s, choiceID: "yes")))
        #expect(texts(f) == ["\(service) recorded your vote. It can't be changed."])
        #expect(f.yourChoice == "Your choice: \u{2068}Yes\u{2069}" && f.results == nil)
    }

    @Test func aVerifiedCheckSaysTheResultsIncludeTheVoteAndShowsTheTally() {
        let s = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified))
        var d = Samples.detail(s, choiceID: "yes")
        d.tally = ["yes": 3, "no": 1]
        d.counts = VoteCounts(eligible: 9, ballots: 4, unhandled: 2)
        d.minBallots = 2
        let f = Samples.facts(Samples.screen(s, detail: d))
        #expect(texts(f).contains("The published results include your vote."))
        #expect(f.results == [
            "Results", "\u{2068}Yes\u{2069}: 3", "\u{2068}No\u{2069}: 1", "4 of 9 eligible members voted.",
            "Enough votes were cast: 4, and the service asked for at least 2.",
            "2 messages sent to \(service) during the vote were not handled; any vote among them was not counted.",
        ])
        d.minBallots = 5
        #expect(Samples.facts(Samples.screen(s, detail: d)).results?.contains("Not enough votes were cast: 4, and the service asked for at least 5.") == true)
    }

    @Test func noNumberIsShownBeforeTheVerifiedResults() {
        let s = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending))
        let f = Samples.facts(Samples.screen(s, detail: Samples.detail(s, choiceID: "yes")))
        #expect(f.results == nil && !texts(f).contains("The published results include your vote."))
        #expect(f.notes.map(\.note) == [.closed, .recorded, .checkPending] && texts(f).last == "VettID will check the published results against your vote.")
    }

    @Test func aConflictFoundAfterAVerifiedCheckIsTheOwnersTextWithTheProofAndNoErrorState() {
        let s = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified), conflict: true)
        let f = Samples.facts(Samples.screen(s))
        #expect(f.notes.map(\.note) == [.closed, .recorded, .inResults, .inResultsConflict])
        #expect(f.notes.last?.text == "**Your vote is in the published results.** \(service) also once showed a different vote under your code. Save the proof and show it to the organisation.")
        #expect(f.notes.last?.note.severity == .note && f.saveProof)
        // Without the flag only the results line shows, and no proof.
        let plain = Samples.facts(Samples.screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .verified))))
        #expect(plain.notes.map(\.note) == [.closed, .recorded, .inResults] && !plain.saveProof)
    }

    /// Owner behaviour 5: the hints of Votes 2 show as Android shows them.
    @Test func theAppsOwnHintsShowAsAndroidShowsThem() {
        let pending = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending, reason: "input"))
        func note(_ s: VoteSummary, _ hint: VoteHint) -> String? {
            Samples.facts(Samples.screen(s) { $0.hint = hint }).notes.last?.text
        }
        #expect(note(pending, VoteHint(resultsProblem: true)) == "VettID could not check the published results of this vote yet. They may be incomplete or not valid. It will try again.")
        #expect(note(pending, VoteHint()) == "VettID could not check the published results of this vote yet. They may be incomplete or not valid. It will try again.", "a pending check with reason input is never the failed title")
        #expect(note(pending, VoteHint(resultsProblem: true, resultsTooLarge: true)) == "VettID can't check the published results of this vote: they are larger than your vault accepts. They may not be valid.")
        let gaveUp = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .gaveUp))
        #expect(note(gaveUp, VoteHint(gaveUp: .site)) == "VettID could not reach the votes site for 7 days, so your vote has not been checked.")
        #expect(note(gaveUp, VoteHint(gaveUp: .unpublished)) == "The results of this vote were not published within 7 days, so your vote has not been checked.")
        #expect(note(gaveUp, VoteHint()) == "VettID could not check the results of this vote within 7 days, so your vote has not been checked.")
        #expect(Samples.facts(Samples.screen(gaveUp)).checkAgain)
        // Missing from the site: a warning at first, "unusual" after ten minutes.
        var late = Samples.open()
        late.site = .notListed
        #expect(note(late, VoteHint())?.hasPrefix("This vote is not on the public site yet.") == true)
        #expect(note(late, VoteHint(notListedSince: Samples.t0.addingTimeInterval(-601)))?.hasPrefix("This vote is still not on the public site, which is unusual.") == true)
        #expect(Samples.facts(Samples.screen(late) { $0.hint = VoteHint(notListedSince: Samples.t0.addingTimeInterval(-601)) }, now: Samples.t0).castEnabled == false)
    }

    @Test func aFailedCheckShowsTheTitleTheBodyAndTheProof() {
        let f = Samples.facts(Samples.screen(Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .failed))))
        let failed = f.notes.first { $0.note == .failed }
        #expect(failed?.heading == "The published results don't match your vote" && failed?.text == "You can save the proof and show it to the organisation.")
        #expect(f.saveProof)
    }

    @Test func aRejectedVoteIsSetAsideWithItsReasonAndTheProof() {
        let f = Samples.facts(Samples.screen(Samples.open(canCast: false, state: .rejected, reason: "anchor")))
        let rejected = f.notes.first { $0.note == .rejected }
        #expect(rejected?.heading == "VettID set this vote aside" && rejected?.text == "The public record of this vote did not check out.")
        #expect(f.saveProof)
    }

    @Test func aMemberCheckAgainOutcomeIsToldWhenTheSiteHadNothingOrCouldNotBeReached() {
        let s = Samples.closed(VoteBallot(state: .recorded), check: VoteCheck(state: .pending))
        let unreachable = Samples.facts(Samples.screen(s) { $0.checkOutcome = .siteUnreachable }).checkOutcome
        #expect(unreachable?.title == "Check with the service" && unreachable?.text == "VettID could not reach the votes site just now. It will try again.")
        let notPublished = Samples.facts(Samples.screen(s) { $0.checkOutcome = .notPublished }).checkOutcome
        #expect(notPublished?.text == "The results of this vote are not on the votes site yet. VettID will try again.")
        #expect(Samples.facts(Samples.screen(s) { $0.checkOutcome = .submitted(.pending) }).checkOutcome == nil)
        #expect(Samples.facts(Samples.screen(s) { $0.checkProblem = VoteProblem(kind: .network) }).checkProblem == FailureKind.network.message(timeScale: 1))
    }

    // MARK: Proof and release (owner behaviour 3)

    @Test func saveTheProofIsOfferedWhereTheVaultHoldsOneAndReleaseOnlyAfterItWasSaved() {
        let s = Samples.closed(VoteBallot(state: .conflict))
        let before = Samples.facts(Samples.screen(s))
        #expect(before.saveProof && !before.release && !before.released)
        let saved = Samples.facts(Samples.screen(s) { $0.proofExported = true; $0.proofSaved = true })
        #expect(saved.release && saved.proofSaved)
        let released = Samples.facts(Samples.screen(s) { $0.proofExported = true; $0.released = true })
        #expect(!released.release && released.released)
        // An open vote's record is not released; a plain final refusal holds no proof.
        let open = Samples.open(canCast: false).with(site: .mismatch)
        #expect(!Samples.facts(Samples.screen(open) { $0.proofExported = true }).release)
        let plain = Samples.closed(VoteBallot(state: .refused, code: "closed"))
        #expect(!Samples.facts(Samples.screen(plain)).saveProof)
        #expect(Samples.facts(Samples.screen(s) { $0.proofSaveFailed = true }).proofSaveFailed)
    }
}

extension VoteSummary {
    func with(site: SiteState) -> VoteSummary {
        var s = self
        s.site = site
        return s
    }
}
