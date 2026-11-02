import Foundation
import Testing
@testable import VettIDVotes

// The table is long literal rows, one per text.
// swiftlint:disable line_length

/// The texts of ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes" word for word, as vettid-android's `feature/votes` `strings.xml`
/// has them (the owner approved them on 2026-10-30, the proposed ones with the Android pull request 230; a changed text is
/// the owner's to approve). Every row is a text's key, what its accessor gives with the arguments "Example" (a name) and
/// 3 + n (a number), and the expected text.
@Suite struct VoteStringsTests {
    struct Row {
        let key: String
        let got: String
        let want: String

        init(_ key: String, _ got: String, _ want: String) {
            self.key = key
            self.got = got
            self.want = want
        }
    }

    static let table: [Row] = [
        Row("votes_title", VoteStrings.votesTitle, "Votes"),
        Row("votes_section_open", VoteStrings.votesSectionOpen, "Open"),
        Row("votes_section_closed", VoteStrings.votesSectionClosed, "Closed"),
        Row("vote_row_closes", VoteStrings.voteRowCloses("Example"), "Closes Example"),
        Row("vote_row_opens", VoteStrings.voteRowOpens("Example"), "Opens Example"),
        Row("vote_row_closed", VoteStrings.voteRowClosed("Example"), "Closed Example"),
        Row("vote_chip_not_voted", VoteStrings.voteChipNotVoted, "Not voted yet"),
        Row("vote_chip_recorded", VoteStrings.voteChipRecorded, "You voted"),
        Row("vote_chip_waiting", VoteStrings.voteChipWaiting, "Waiting for the service"),
        Row("vote_chip_checking", VoteStrings.voteChipChecking, "Being checked"),
        Row("vote_chip_results", VoteStrings.voteChipResults, "Results are out"),
        Row("vote_chip_problem", VoteStrings.voteChipProblem, "Needs your attention"),
        Row("vote_chip_missed", VoteStrings.voteChipMissed, "You didn't vote"),
        Row("vote_written_by", VoteStrings.voteWrittenBy("Example"), "Written by Example"),
        Row("vote_quorum_line", VoteStrings.voteQuorumLine("Example"), "Quorum, as the service states it: Example"),
        Row("vote_binding_yes", VoteStrings.voteBindingYes, "The service says this vote is binding."),
        Row("vote_binding_no", VoteStrings.voteBindingNo, "The service says this vote is not binding."),
        Row("vote_extended", VoteStrings.voteExtended("Example"), "The closing time was extended to Example."),
        Row("vote_choose", VoteStrings.voteChoose, "Choose one"),
        Row("vote_cast_button", VoteStrings.voteCastButton, "Cast your vote"),
        Row("vote_disclosure", VoteStrings.voteDisclosure("Example"), "Example will see how you vote and keep that record. The published results show only an anonymous code for you."),
        Row("vote_final", VoteStrings.voteFinal, "Your vote can't be changed after you cast it."),
        Row("vote_confirm_title", VoteStrings.voteConfirmTitle("Example"), "Vote “Example”?"),
        Row("vote_confirm_yes", VoteStrings.voteConfirmYes, "Cast vote"),
        Row("vote_confirm_back", VoteStrings.voteConfirmBack, "Back"),
        Row("vote_password_title", VoteStrings.votePasswordTitle, "Confirm with your credential password"),
        Row("vote_password_body", VoteStrings.votePasswordBody, "Your vote is signed with your credential. Enter your credential password."),
        Row("vote_state_sending", VoteStrings.voteStateSending("Example"), "Sending your vote to Example…"),
        Row("vote_state_waiting", VoteStrings.voteStateWaiting("Example"), "Waiting for Example to confirm. Your vote is saved on your vault and is sent again until Example answers."),
        Row("vote_state_recorded", VoteStrings.voteStateRecorded("Example"), "Example recorded your vote. It can't be changed."),
        Row("vote_state_in_results", VoteStrings.voteStateInResults, "The published results include your vote."),
        Row("vote_conflict_after_verified", VoteStrings.voteConflictAfterVerified("Example"), "**Your vote is in the published results.** Example also once showed a different vote under your code. Save the proof and show it to the organisation."),
        Row("vote_state_unconfirmed", VoteStrings.voteStateUnconfirmed("Example"), "Not confirmed. Example sent no receipt for your vote, and the published results don't settle whether it counted."),
        Row("vote_state_didnt_vote", VoteStrings.voteStateDidntVote, "You didn't vote in this one."),
        Row("vote_check_with_service", VoteStrings.voteCheckWithService, "Check with the service"),
        Row("vote_check_pending", VoteStrings.voteCheckPending, "VettID will check the published results against your vote."),
        Row("vote_check_gave_up_site", VoteStrings.voteCheckGaveUpSite, "VettID could not reach the votes site for 7 days, so your vote has not been checked."),
        Row("vote_check_gave_up_unpublished", VoteStrings.voteCheckGaveUpUnpublished, "The results of this vote were not published within 7 days, so your vote has not been checked."),
        Row("vote_check_again", VoteStrings.voteCheckAgain, "Check again"),
        Row("vote_failed_title", VoteStrings.voteFailedTitle, "The published results don't match your vote"),
        Row("vote_failed_body", VoteStrings.voteFailedBody, "You can save the proof and show it to the organisation."),
        Row("vote_conflict_body", VoteStrings.voteConflictBody("Example"), "Example holds a different vote under your code than the one you cast. Save the proof and show it to the organisation."),
        Row("vote_state_late_pending", VoteStrings.voteStateLatePending("Example"), "Example says the vote had closed. VettID is asking whether an earlier send arrived in time."),
        Row("vote_refused_late", VoteStrings.voteRefusedLate, "The vote had closed when your vote arrived, so it was not counted."),
        Row("vote_refused_not_active", VoteStrings.voteRefusedNotActive("Example"), "Example says you are no longer a member for this vote, so your vote was not counted."),
        Row("vote_refused_not_eligible", VoteStrings.voteRefusedNotEligible("Example"), "Example says you were not on the list for this vote. You can save the proof and show it to the organisation."),
        Row("vote_refused_bad_ballot", VoteStrings.voteRefusedBadBallot("Example"), "Example did not accept your vote. You can save the proof and show it to the organisation."),
        Row("vote_refused_ended", VoteStrings.voteRefusedEnded("Example"), "Your connection to Example ended before your vote was recorded."),
        Row("vote_not_signed_in", VoteStrings.voteNotSignedIn("Example"), "Before you can vote, sign in to Example once with VettID. This lets Example check that your vote is yours."),
        Row("vote_closing_soon", VoteStrings.voteClosingSoon, "This vote closes in less than 2 minutes. It is too late to cast your vote from this phone."),
        Row("vote_not_open", VoteStrings.voteNotOpen("Example"), "This vote opens Example."),
        Row("vote_closed_banner", VoteStrings.voteClosedBanner, "This vote has closed."),
        Row("vote_checking_list", VoteStrings.voteCheckingList, "VettID is checking this vote. It needs the list of services from votes.vettid.org. Check that this phone is online."),
        Row("vote_checking_site", VoteStrings.voteCheckingSite, "VettID is checking this vote. It is waiting for the vote's documents from votes.vettid.org."),
        Row("vote_no_connection", VoteStrings.voteNoConnection("Example"), "You are no longer connected to Example, so you can't vote."),
        Row("vote_results_title", VoteStrings.voteResultsTitle, "Results"),
        Row("vote_results_turnout", VoteStrings.voteResultsTurnout(4, 5), "4 of 5 eligible members voted."),
        Row("vote_results_row", VoteStrings.voteResultsRow("Example", 5), "Example: 5"),
        Row("vote_results_unhandled", VoteStrings.voteResultsUnhandled(4, "Example"), "4 messages sent to Example during the vote were not handled; any vote among them was not counted."),
        Row("vote_quorum_met", VoteStrings.voteQuorumMet(4, 5), "Enough votes were cast: 4, and the service asked for at least 5."),
        Row("vote_quorum_not_met", VoteStrings.voteQuorumNotMet(4, 5), "Not enough votes were cast: 4, and the service asked for at least 5."),
        Row("vote_save_proof", VoteStrings.voteSaveProof, "Save the proof"),
        Row("vote_save_proof_warning", VoteStrings.voteSaveProofWarning, "The file shows how you voted. Keep it private, and share it only with the organisation."),
        Row("vote_rejected_title", VoteStrings.voteRejectedTitle, "VettID set this vote aside"),
        Row("vote_checking_trust", VoteStrings.voteCheckingTrust, "VettID can't finish checking this vote yet: its list of trusted logs may be out of date. Update VettID if this lasts."),
        Row("vote_checking_clock", VoteStrings.voteCheckingClock, "VettID can't finish checking this vote yet because of a time check on VettID's side. It will try again."),
        Row("vote_checking_restore", VoteStrings.voteCheckingRestore("Example"), "VettID is asking Example what it recorded for you before you can vote."),
        Row("vote_not_published", VoteStrings.voteNotPublished, "This vote is not on the public site yet. You can still vote: VettID will compare it with the public copy when it appears."),
        Row("vote_site_unreachable", VoteStrings.voteSiteUnreachable, "VettID could not reach the votes site to compare this vote with the public copy. You can still vote: VettID will compare it later."),
        Row("vote_dropped", VoteStrings.voteDropped("Example", 5), "Example has more votes under way than your vault can keep, so 5 were not kept."),
        Row("vote_problems", VoteStrings.voteProblems("Example", 5), "Example has 5 unresolved vote problems. Save the proof of each and release them to receive new votes from Example."),
        Row("vote_site_mismatch", VoteStrings.voteSiteMismatch, "The vote you received differs from the one published on the public site, so you can't vote in it. You can save the proof."),
        Row("vote_site_mismatch_after", VoteStrings.voteSiteMismatchAfter, "The vote you voted on differs from the one published on the public site, so your vote may not count. Save the proof and show it to the organisation."),
        Row("vote_unpublished", VoteStrings.voteUnpublished, "This vote was never published on the public site. Your vote may not count. Save the proof."),
        Row("vote_not_listed_late", VoteStrings.voteNotListedLate, "This vote is still not on the public site, which is unusual. You can vote, but keep the proof."),
        Row("vote_restore_title", VoteStrings.voteRestoreTitle, "Is this your vote?"),
        Row("vote_restore_body", VoteStrings.voteRestoreBody("Example", "Example", "Example"), "Example says it recorded this vote for you: “Example” on “Example”."),
        Row("vote_restore_yes", VoteStrings.voteRestoreYes, "Yes, it's mine"),
        Row("vote_restore_no", VoteStrings.voteRestoreNo, "No, it isn't mine"),
        Row("vote_reconnect_title", VoteStrings.voteReconnectTitle, "Connect again to vote"),
        Row("vote_reconnect_body", VoteStrings.voteReconnectBody("Example"), "Example is registered with VettID as a service. This connection was made before it said it was a service, so it can't take part in votes. Remove it and connect again from a new invitation from Example."),
        Row("vote_reconnect_open", VoteStrings.voteReconnectOpen, "Open the connection"),
        Row("vote_connection_row", VoteStrings.voteConnectionRow("Example"), "Votes from Example"),
        Row("vote_remove_warning", VoteStrings.voteRemoveWarning("Example"), "You have a vote with Example that isn't finished. If you remove this connection you can't vote in it."),
        Row("vote_check_results_problem", VoteStrings.voteCheckResultsProblem, "VettID could not check the published results of this vote yet. They may be incomplete or not valid. It will try again."),
        Row("vote_check_gave_up", VoteStrings.voteCheckGaveUp, "VettID could not check the results of this vote within 7 days, so your vote has not been checked."),
        Row("vote_checking_other", VoteStrings.voteCheckingOther, "VettID is still checking this vote. You can vote when the check is done."),
        Row("vote_cannot_cast_other", VoteStrings.voteCannotCastOther, "You can't vote in this one right now."),
        Row("vote_disputed_body", VoteStrings.voteDisputedBody("Example"), "Example holds a vote under your code that you said is not yours. Save the proof and show it to the organisation."),
        Row("vote_rejected_signature", VoteStrings.voteRejectedSignature, "The service's signature on this vote did not check out."),
        Row("vote_rejected_anchor", VoteStrings.voteRejectedAnchor, "The public record of this vote did not check out."),
        Row("vote_rejected_record", VoteStrings.voteRejectedRecord, "The list of members for this vote did not check out."),
        Row("vote_rejected_other", VoteStrings.voteRejectedOther, "This vote could not be read as a valid vote from the service."),
        Row("vote_check_site_unreachable_now", VoteStrings.voteCheckSiteUnreachableNow, "VettID could not reach the votes site just now. It will try again."),
        Row("vote_check_not_published_now", VoteStrings.voteCheckNotPublishedNow, "The results of this vote are not on the votes site yet. VettID will try again."),
        Row("vote_service_fallback", VoteStrings.voteServiceFallback, "The service"),
        Row("vote_your_choice", VoteStrings.voteYourChoice("Example"), "Your choice: Example"),
        Row("vote_service_label", VoteStrings.voteServiceLabel, "Service"),
        Row("vote_name_by_service", VoteStrings.voteNameByService, "Name given by the service"),
        Row("vote_closes_line", VoteStrings.voteClosesLine("Example"), "Closes Example"),
        Row("vote_row_description", VoteStrings.voteRowDescription("Example", "Example", "Example"), "Example, from the service Example, Example"),
        Row("votes_empty_title", VoteStrings.votesEmptyTitle, "No votes"),
        Row("votes_empty_body", VoteStrings.votesEmptyBody, "Votes from services you are connected to appear here."),
        Row("votes_error_title", VoteStrings.votesErrorTitle, "Could not load your votes"),
        Row("vote_error_title", VoteStrings.voteErrorTitle, "Could not load this vote"),
        Row("vote_gone_title", VoteStrings.voteGoneTitle, "This vote is no longer here"),
        Row("votes_retry", VoteStrings.votesRetry, "Try again"),
        Row("vote_password_label", VoteStrings.votePasswordLabel, "Credential password"),
        Row("vote_password_confirm", VoteStrings.votePasswordConfirm, "Confirm"),
        Row("vote_cast_failed_title", VoteStrings.voteCastFailedTitle, "Your vote was not sent"),
        Row("vote_cast_unknown_title", VoteStrings.voteCastUnknownTitle, "VettID got no answer"),
        Row("vote_cast_unanswered", VoteStrings.voteCastUnanswered, "Your vote may have been sent. This screen shows it as sent once VettID knows. If it does not, you can cast again. If your first vote did arrive, it is the one that counts: a vote can't be changed."),
        Row("vote_already_voted", VoteStrings.voteAlreadyVoted("Example"), "You had already voted: Example. Your vote can't be changed."),
        Row("vote_already_voted_any", VoteStrings.voteAlreadyVotedAny, "You had already voted. Your vote can't be changed."),
        Row("vote_window_not_closed_title", VoteStrings.voteWindowNotClosedTitle, "The unlock window may still be open"),
        Row("vote_window_not_closed_plain", VoteStrings.voteWindowNotClosedPlain, "VettID could not close the credential unlock window after your vote. It closes by itself."),
        Row("vote_window_close_now", VoteStrings.voteWindowCloseNow, "Close it now"),
        Row("vote_check_results_too_large", VoteStrings.voteCheckResultsTooLarge, "VettID can't check the published results of this vote: they are larger than your vault accepts. They may not be valid."),
        Row("vote_proof_saved", VoteStrings.voteProofSaved, "The proof was saved."),
        Row("vote_proof_failed", VoteStrings.voteProofFailed, "The proof could not be saved. Try again."),
        Row("vote_proof_save", VoteStrings.voteProofSave, "Save"),
        Row("vote_release", VoteStrings.voteRelease, "Release"),
        Row("vote_release_title", VoteStrings.voteReleaseTitle, "Release this vote record?"),
        Row("vote_release_body", VoteStrings.voteReleaseBody("Example"), "This lets your vault keep new votes from Example. Every signed item that is not on the public site stays on your vault. Nothing is sent anywhere. Enter your vault PIN."),
        Row("vote_release_pin", VoteStrings.voteReleasePin, "Vault PIN"),
        Row("vote_release_not_saved", VoteStrings.voteReleaseNotSaved, "Save the proof first: the record can be released only after it was saved."),
        Row("vote_released", VoteStrings.voteReleased, "The vote record was released."),
    ]

    @Test func everyTextIsWordForWord() {
        #expect(Self.table.count == 127)
        for row in Self.table { #expect(row.got == row.want, "\(row.key)") }
    }

    /// Every key of the catalog is in the table (and the unlock window's plural, which has its own test).
    @Test func theTableHoldsEveryKeyOfTheCatalog() throws {
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: VoteTextsTests.catalog)) as? [String: Any])
        let keys = Set(try #require((doc["strings"] as? [String: Any])?.keys))
        #expect(keys == Set(Self.table.map(\.key)).union(["vote_window_not_closed", "vote_cancel"]))
    }
}
// swiftlint:enable line_length
