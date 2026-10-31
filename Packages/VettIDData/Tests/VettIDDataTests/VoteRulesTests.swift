import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData

// Test data: long literal rows are clearer than wrapped ones.
// swiftlint:disable line_length

/// How a vote reads (IOS-PLAN §4.16, ANDROID-PLAN 0.1.108 "Votes"): a table over the vault's states, and the "never
/// success" rules. Mirrors vettid-android `VoteRulesTest`.
struct VoteRulesTests {
    private func vote(
        _ state: VoteState = .open, _ ballot: VoteBallot? = nil, _ check: VoteCheck? = nil, conflictEvidence: Bool = false,
        confirmPending: Bool = false, canCast: Bool? = nil, cannotCast: String? = nil, site: SiteState? = nil, reason: String? = nil
    ) -> VoteSummary {
        VoteSummary(
            proposalID: "P", connectionID: "C", title: "T", state: state, reason: reason, ballot: ballot, check: check,
            conflictEvidence: conflictEvidence, confirmPending: confirmPending, canCast: canCast ?? (ballot == nil && state == .open),
            cannotCast: cannotCast, site: site
        )
    }

    private func ballot(_ s: BallotState, _ code: String? = nil, reason: String? = nil) -> VoteBallot { VoteBallot(state: s, code: code, reason: reason) }
    private func check(_ s: CheckState, _ reason: String? = nil) -> VoteCheck { VoteCheck(state: s, reason: reason) }

    @Test func aBallotStateAndACheckStateEachShowTheirText() {
        let table: [(VoteSummary, VoteNote)] = [
            (vote(.open, ballot(.sending)), .sending),
            (vote(.open, ballot(.waiting, reason: "not_open")), .waiting),
            (vote(.open, ballot(.waiting, reason: "not_signed_in")), .notSignedIn),
            (vote(.open, ballot(.waiting, reason: "closed")), .latePending),
            (vote(.open, ballot(.recorded)), .recorded),
            (vote(.open, ballot(.refused, "closed")), .refusedLate),
            (vote(.open, ballot(.refused, "late")), .refusedLate),
            (vote(.open, ballot(.refused, "not_active")), .refusedNotActive),
            (vote(.open, ballot(.refused, "not_eligible")), .refusedNotEligible),
            (vote(.open, ballot(.refused, "bad_ballot")), .refusedBadBallot),
            (vote(.open, ballot(.refused, "connection_ended")), .refusedEnded),
            (vote(.open, ballot(.conflict)), .conflict),
            (vote(.open, ballot(.disputed)), .disputed),
        ]
        for (v, want) in table { #expect(VoteRules.notes(v).contains(want), "\(want) in \(VoteRules.notes(v))") }
    }

    @Test func aBallotStateNobodyKnowsIsNeverShownAsSuccess() {
        let notes = VoteRules.notes(vote(.open, ballot(.unknown)))
        #expect(notes.contains(.waiting))
        #expect(!notes.contains(.recorded) && !notes.contains(.inResults))
        #expect(VoteRules.notes(vote(.open, ballot(.refused, "something_new"))).contains(.refusedBadBallot))
        #expect(BallotState.of("new") == .unknown && BallotState.of("") == .unknown && BallotState.of(nil) == .unknown)
        #expect(VoteState.of("") == .unknown && CheckState.of("gave_up") == .gaveUp)
    }

    @Test func aWaitingBallotNeverShowsAsFailed() {
        for reason in [nil, "not_open", "not_signed_in", "closed", "bad_ballot"] {
            let notes = VoteRules.notes(vote(.open, ballot(.waiting, reason: reason)))
            #expect(!notes.contains(.failed))
            #expect(!notes.contains { $0.severity == .error })
        }
    }

    @Test func theResultsLineAppearsOnlyForAVerifiedCheckOfARecordedBallot() {
        for c in CheckState.allCases {
            let notes = VoteRules.notes(vote(.closed, ballot(.recorded), check(c)))
            #expect((c == .verified) == notes.contains(.inResults), "\(c)")
        }
        // A ballot with no receipt is not "included" even if the check is verified (it was refused or empty).
        #expect(!VoteRules.notes(vote(.closed, ballot(.sending), check(.verified))).contains(.inResults))
    }

    @Test func conflictEvidenceUnderAVerifiedCheckIsANoteUnderTheResultsLineNotAnError() {
        var v = vote(.closed, ballot(.recorded), check(.verified), conflictEvidence: true)
        let notes = VoteRules.notes(v)
        #expect(notes == [.closed, .recorded, .inResults, .inResultsConflict])
        #expect(VoteNote.inResultsConflict.severity == .note)
        #expect(!notes.contains(.failed))
        #expect(VoteRules.hasProof(v))
        #expect(VoteRules.chip(v) == .problem)
        // Without the flag, only the first line.
        v.conflictEvidence = false
        let plain = VoteRules.notes(v)
        #expect(!plain.contains(.inResultsConflict))
        #expect(plain.contains(.inResults))
    }

    @Test func aPendingCheckWithReasonInputIsAProblemWithTheResultsAndNeverFailed() {
        let v = vote(.closed, ballot(.recorded), check(.pending, "input"))
        let notes = VoteRules.notes(v)
        #expect(notes.contains(.checkResultsProblem))
        #expect(!notes.contains(.failed))
        #expect(!VoteRules.hasProof(v))
        #expect(VoteRules.chip(v) == .checking)
    }

    @Test func aPendingCheckOnTheVaultsOwnReasonSaysSo() {
        #expect(VoteRules.notes(vote(.closed, ballot(.recorded), check(.pending, "clock"))).contains(.checkingClock))
        #expect(VoteRules.notes(vote(.closed, ballot(.recorded), check(.pending, "trust_root"))).contains(.checkingTrust))
        #expect(VoteRules.notes(vote(.closed, ballot(.recorded), check(.pending, "service_list"))).contains(.checkingList))
        #expect(VoteRules.notes(vote(.closed, ballot(.recorded), check(.pending))).contains(.checkPending))
    }

    @Test func resultsTooLargeAreAProblemWithoutATryAgain() {
        let notes = VoteRules.notes(vote(.closed, ballot(.recorded), check(.pending)), resultsProblem: true, resultsTooLarge: true)
        #expect(notes.contains(.checkResultsTooLarge))
        #expect(!notes.contains(.checkResultsProblem))
    }

    @Test func aFailedCheckShowsTheMismatchAndTheProof() {
        let v = vote(.closed, ballot(.recorded), check(.failed))
        #expect(VoteRules.notes(v).contains(.failed))
        #expect(VoteRules.hasProof(v))
        #expect(VoteRules.chip(v) == .problem)
    }

    @Test func gaveUpSaysWhichOfTwoThingsWhenTheAppKnows() {
        let v = vote(.closed, ballot(.recorded), check(.gaveUp))
        #expect(VoteRules.notes(v, gaveUp: .site).contains(.checkGaveUpSite))
        #expect(VoteRules.notes(v, gaveUp: .unpublished).contains(.checkGaveUpUnpublished))
        #expect(VoteRules.notes(v).contains(.checkGaveUp))
    }

    @Test func theAppsOwnFindInTheResultsIsShownWhileTheVaultHasNotJudged() {
        let v = vote(.closed, ballot(.recorded))
        #expect(VoteRules.notes(v, resultsProblem: true).contains(.checkResultsProblem))
        #expect(!VoteRules.notes(v).contains(.checkResultsProblem))
    }

    @Test func aClosedVoteWithoutABallotSaysSoOnlyAfterAVerifiedCheck() {
        #expect(VoteRules.notes(vote(.closed, nil, check(.verified))).contains(.didntVote))
        #expect(!VoteRules.notes(vote(.closed, nil, check(.pending))).contains(.didntVote))
        #expect(VoteRules.chip(vote(.closed)) == .missed)
    }

    @Test func theReasonACastIsNotOfferedIsWrittenForEachCode() {
        let table: [String: VoteNote] = [
            "not_open": .notOpen, "closed": .closed, "closing": .closingSoon, "site_mismatch": .siteMismatch,
            "connection_unavailable": .noConnection, "not_signed_in": .notSignedIn, "something_new": .cannotCastOther,
        ]
        for (code, want) in table { #expect(VoteRules.cannotCastNote(vote(canCast: false, cannotCast: code)) == want, "\(code)") }
        #expect(VoteRules.cannotCastNote(vote(canCast: false, cannotCast: "already_voted")) == nil, "the ballot says it")
        #expect(VoteRules.cannotCastNote(vote()) == nil)
    }

    @Test func aCheckingVoteSaysWhyForEachReasonAndCannotBeCast() {
        let table: [String: VoteNote] = [
            "service_list": .checkingList, "trust_root": .checkingTrust, "clock": .checkingClock, "site": .checkingSite,
            "restore": .checkingRestore, "something_new": .checkingOther,
        ]
        for (reason, want) in table {
            let v = vote(.checking, canCast: false, cannotCast: "checking", reason: reason)
            #expect(VoteRules.notes(v) == [want], "\(reason)")
            #expect(!VoteRules.castAllowed(v))
            #expect(VoteRules.chip(v) == .checking)
        }
    }

    @Test func noCastWhileAConfirmationWaitsOrWhenTheVaultSaysNo() {
        #expect(VoteRules.castAllowed(vote()))
        #expect(!VoteRules.castAllowed(vote(confirmPending: true, canCast: true)))
        #expect(!VoteRules.castAllowed(vote(canCast: false, cannotCast: "closing")))
        #expect(!VoteRules.castAllowed(vote(.open, ballot(.sending), canCast: true)))
        #expect(!VoteRules.castAllowed(vote(.upcoming, canCast: true)))
        #expect(VoteRules.cannotCastNote(vote(confirmPending: true, canCast: true)) == .checkingRestore)
    }

    @Test func siteNotesAreWarningsBeforeACastAndTheAfterTextAfterOne() {
        #expect(VoteRules.notes(vote(site: .notListed)).contains(.notPublished))
        #expect(VoteRules.notes(vote(site: .notListed), notListedLate: true).contains(.notListedLate))
        #expect(VoteRules.notes(vote(.closed, site: .notListed)).contains(.notListedLate))
        #expect(VoteRules.notes(vote(site: .unreachable)).contains(.siteUnreachable))
        #expect(VoteRules.notes(vote(canCast: false, cannotCast: "site_mismatch", site: .mismatch)).contains(.siteMismatch))
        #expect(VoteRules.notes(vote(.open, ballot(.recorded), site: .mismatch)).contains(.siteMismatchAfter))
        #expect(VoteRules.notes(vote(site: .unpublished)).contains(.unpublished))
        #expect(VoteRules.hasProof(vote(site: .unpublished)))
        #expect(!VoteRules.hasProof(vote(site: .notListed)))
        // A warning does not stop a cast.
        #expect(VoteRules.castAllowed(vote(site: .unreachable)))
    }

    @Test func aRejectedVoteSaysWhyAndOffersTheProof() {
        let v = vote(.rejected, canCast: false, cannotCast: "closed", reason: "signature")
        #expect(VoteRules.notes(v) == [.rejected])
        #expect(VoteRules.hasProof(v))
        #expect(VoteRules.rejectedWhy("signature") == .signature)
        #expect(VoteRules.rejectedWhy("anchor") == .anchor)
        #expect(VoteRules.rejectedWhy("record") == .record)
        #expect(VoteRules.rejectedWhy("malformed") == .other)
        #expect(VoteRules.chip(v) == .problem)
        #expect(!VoteRules.inOpenSection(vote(.closed)))
        #expect(VoteRules.inOpenSection(v))
    }

    @Test func theProofIsOfferedForProblemsOnlyAndNotForAPlainFinalRefusal() {
        #expect(VoteRules.hasProof(vote(.open, ballot(.conflict))))
        #expect(VoteRules.hasProof(vote(.open, ballot(.disputed))))
        #expect(VoteRules.hasProof(vote(.open, ballot(.refused, "not_eligible"))))
        #expect(VoteRules.hasProof(vote(.open, ballot(.refused, "bad_ballot"))))
        #expect(!VoteRules.hasProof(vote(.open, ballot(.refused, "closed"))))
        #expect(!VoteRules.hasProof(vote(.open, ballot(.refused, "late"))))
        #expect(!VoteRules.hasProof(vote(.open, ballot(.refused, "connection_ended"))))
        // The vault makes not_active a problem record: it needs the proof and then Release.
        #expect(VoteRules.hasProof(vote(.open, ballot(.refused, "not_active"))))
        #expect(!VoteRules.hasProof(vote(.open, ballot(.recorded))))
    }

    @Test func chipsReadLikeTheScreenSays() {
        #expect(VoteRules.chip(vote()) == .notVoted)
        #expect(VoteRules.chip(vote(.upcoming)) == .notVoted)
        #expect(VoteRules.chip(vote(.open, ballot(.recorded))) == .recorded)
        #expect(VoteRules.chip(vote(.open, ballot(.sending))) == .waiting)
        #expect(VoteRules.chip(vote(.open, ballot(.waiting))) == .waiting)
        #expect(VoteRules.chip(vote(.closed, ballot(.recorded), check(.verified))) == .results)
        #expect(VoteRules.chip(vote(.closed, ballot(.recorded), check(.unconfirmed))) == .results)
        #expect(VoteRules.chip(vote(.closed, ballot(.recorded), check(.pending))) == .checking)
        #expect(VoteRules.chip(vote(.open, ballot(.refused, "closed"))) == .problem)
        #expect(VoteRules.chip(vote(.unknown)) == .checking)
    }

    @Test func theBadgeCountsOpenVotesNotYetVotedOnAndNothingElse() {
        let list = [
            vote(), vote(), vote(.upcoming), vote(.checking), vote(.closed), vote(.open, ballot(.recorded)), vote(.open, ballot(.sending)),
        ]
        #expect(VoteRules.badge(list) == 2)
        #expect(VoteRules.badge([]) == 0)
    }

    @Test func theEntryShowsOnlyWithAVoteOrAReconnectFromAVaultThatAnswers() {
        let r = ReconnectEntry(connectionID: "C9", serviceID: "s", name: "N")
        #expect(VoteRules.entry([], reconnect: [], availability: .available) == VotesEntry(shown: false, badge: 0))
        #expect(VoteRules.entry([vote()], reconnect: [], availability: .available) == VotesEntry(shown: true, badge: 1))
        #expect(VoteRules.entry([], reconnect: [r], availability: .available) == VotesEntry(shown: true, badge: 0))
        #expect(VoteRules.entry([vote()], reconnect: [r], availability: .unsupported) == VotesEntry())
        #expect(VoteRules.entry([vote()], reconnect: [r], availability: .unknown) == VotesEntry())
    }

    @Test func aVoteIsUnfinishedWhileOpenOrItsBallotIsNotFinal() {
        #expect(VoteRules.unfinished(vote()))
        #expect(VoteRules.unfinished(vote(.upcoming)))
        #expect(VoteRules.unfinished(vote(.checking)))
        #expect(VoteRules.unfinished(vote(.closed, ballot(.sending))))
        #expect(VoteRules.unfinished(vote(.closed, ballot(.waiting))))
        #expect(!VoteRules.unfinished(vote(.closed, ballot(.recorded))))
        #expect(!VoteRules.unfinished(vote(.closed)))
    }

    @Test func theWireReadsAListingWithoutTrustingIt() throws {
        let o = try StrictJson.parseObject(#"{"votes":[{"proposal_id":"P1","connection_id":"C1","title":"A","state":"newstate","ballot":{"state":"x"},"check":{"state":"y"},"site":"z"},{"connection_id":"C2"},"junk"],"dropped":[{"count":2}],"problems":[],"reconnect":[{"connection_id":"C9","service_id":"s","name":"N"}],"list_version":4,"list_sha256":"AA"}"#)
        let l = VoteWire.listing(o)
        // An entry without both ids is not listed; an unknown state is shown as being checked.
        #expect(l.votes.count == 1)
        #expect(l.votes.first?.state == .unknown)
        #expect(l.votes.first?.ballot?.state == .unknown)
        #expect(l.votes.first?.check?.state == .unknown)
        #expect(l.votes.first?.site == nil)
        #expect(l.dropped.isEmpty)
        #expect(l.listVersion == 4)
        #expect(l.listSha256 == "AA")
        #expect(l.reconnect == [ReconnectEntry(connectionID: "C9", serviceID: "s", name: "N")])
    }

    @Test func theWireReadsAVoteWithItsTextAsPlainCleanedText() throws {
        let o = try StrictJson.parseObject(#"{"proposal_id":"P","connection_id":"C","title":"Budget‮ 2027\n<b>x</b>","state":"closed","opens_at":"2026-11-01T10:00:00.000Z","closes_at":"2026-11-02T10:00:00.000Z","ballot":{"state":"recorded","code":"K7"},"check":{"state":"verified","due_at":"2026-11-03T10:00:00.000Z"},"conflict_evidence":true,"confirm_pending":false,"can_cast":false,"cannot_cast":"closed","site":"matches","text":"Line one\u0007\n\n Line two ‭","choices":[{"id":"yes","label":"Yes"},{"id":"no","label":"\u200b"},{"label":"no id"}],"quorum":{"text":"Half","min_ballots":2},"binding":true,"record_tag":"AAAA","choice_id":"yes","extensions":1,"tally":{"yes":2,"no":1},"counts":{"eligible":3,"ballots":3,"removed":0,"unhandled":0},"service_ballot":{"choice_id":"no","msg_ms":1}}"#)
        let d = try #require(VoteWire.detail(o))
        #expect(d.summary.title == "Budget 2027 <b>x</b>")
        #expect(d.summary.state == .closed)
        #expect(d.summary.ballot == VoteBallot(state: .recorded, code: "K7"))
        #expect(d.summary.check?.state == .verified)
        #expect(d.summary.check?.dueAt != nil)
        #expect(d.summary.opensAt != nil && d.summary.closesAt != nil)
        #expect(d.summary.conflictEvidence && !d.summary.confirmPending && !d.summary.canCast)
        #expect(d.summary.site == .matches)
        #expect(!d.text.unicodeScalars.contains { $0.value == 0x07 || $0.value == 0x202D || $0.value == 0x202E })
        #expect(d.text.hasPrefix("Line one"))
        #expect(d.choices == [VoteChoice(id: "yes", label: "Yes"), VoteChoice(id: "no", label: "no")])
        #expect(d.quorumText == "Half" && d.minBallots == 2 && d.binding == true)
        #expect(d.recordTag == "AAAA" && d.choiceID == "yes" && d.extensions == 1)
        #expect(d.tally == ["yes": 2, "no": 1])
        #expect(d.counts == VoteCounts(eligible: 3, ballots: 3))
        #expect(d.serviceBallotChoiceID == "no")
        // Nothing of the vote's content in a log line or a debug description.
        #expect(!"\(d)".contains("yes") && !String(reflecting: d).contains("Line"))
    }

    @Test func theTitleIsCutAtEightyCodePoints() {
        #expect(VoteWire.cleanTitle(String(repeating: "a", count: 200)).unicodeScalars.count == 80)
        #expect(VoteWire.cleanTitle(nil).isEmpty)
        #expect(VoteWire.cleanTitle("\u{200B}").isEmpty)
    }

    @Test func theKeyOfAVoteIsThePairNeverTheProposalIdAlone() {
        #expect(VoteKey(connectionID: "a", proposalID: "b") != VoteKey(connectionID: "b", proposalID: "a"))
        #expect(vote().key == VoteKey(connectionID: "C", proposalID: "P"))
    }
}

// swiftlint:enable line_length
