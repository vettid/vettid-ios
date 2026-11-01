import Foundation

// swiftlint:disable file_length type_body_length line_length

/// The texts of the Votes screens: every string of vettid-android `feature/votes` `strings.xml` (ANDROID-PLAN 0.1.102 to
/// 0.1.108 §4 "Votes", approved by the owner on 2026-10-30, the proposed ones with them), word for word under the same
/// names, in `Localizable.xcstrings`. `**x**` marks bold text: ``boldMarked(_:)`` renders it, the asterisks are never
/// shown. A changed text is the owner's to approve (``VoteStringsTests``).
public enum VoteStrings {
    /// The bundle of these texts (the tests read every key from it).
    public static var bundle: Bundle { .module }

    public static var votesTitle: String {
        String(localized: "votes_title", defaultValue: "Votes", bundle: .module)
    }

    public static var votesSectionOpen: String {
        String(localized: "votes_section_open", defaultValue: "Open", bundle: .module)
    }

    public static var votesSectionClosed: String {
        String(localized: "votes_section_closed", defaultValue: "Closed", bundle: .module)
    }

    public static func voteRowCloses(_ a1: String) -> String {
        String(localized: "vote_row_closes", defaultValue: "Closes \(a1)", bundle: .module)
    }

    public static func voteRowOpens(_ a1: String) -> String {
        String(localized: "vote_row_opens", defaultValue: "Opens \(a1)", bundle: .module)
    }

    public static func voteRowClosed(_ a1: String) -> String {
        String(localized: "vote_row_closed", defaultValue: "Closed \(a1)", bundle: .module)
    }

    public static var voteChipNotVoted: String {
        String(localized: "vote_chip_not_voted", defaultValue: "Not voted yet", bundle: .module)
    }

    public static var voteChipRecorded: String {
        String(localized: "vote_chip_recorded", defaultValue: "You voted", bundle: .module)
    }

    public static var voteChipWaiting: String {
        String(localized: "vote_chip_waiting", defaultValue: "Waiting for the service", bundle: .module)
    }

    public static var voteChipChecking: String {
        String(localized: "vote_chip_checking", defaultValue: "Being checked", bundle: .module)
    }

    public static var voteChipResults: String {
        String(localized: "vote_chip_results", defaultValue: "Results are out", bundle: .module)
    }

    public static var voteChipProblem: String {
        String(localized: "vote_chip_problem", defaultValue: "Needs your attention", bundle: .module)
    }

    public static var voteChipMissed: String {
        String(localized: "vote_chip_missed", defaultValue: "You didn't vote", bundle: .module)
    }

    public static func voteWrittenBy(_ a1: String) -> String {
        String(localized: "vote_written_by", defaultValue: "Written by \(a1)", bundle: .module)
    }

    public static func voteQuorumLine(_ a1: String) -> String {
        String(localized: "vote_quorum_line", defaultValue: "Quorum, as the service states it: \(a1)", bundle: .module)
    }

    public static var voteBindingYes: String {
        String(localized: "vote_binding_yes", defaultValue: "The service says this vote is binding.", bundle: .module)
    }

    public static var voteBindingNo: String {
        String(localized: "vote_binding_no", defaultValue: "The service says this vote is not binding.", bundle: .module)
    }

    public static func voteExtended(_ a1: String) -> String {
        String(localized: "vote_extended", defaultValue: "The closing time was extended to \(a1).", bundle: .module)
    }

    public static var voteChoose: String {
        String(localized: "vote_choose", defaultValue: "Choose one", bundle: .module)
    }

    public static var voteCastButton: String {
        String(localized: "vote_cast_button", defaultValue: "Cast your vote", bundle: .module)
    }

    public static func voteDisclosure(_ a1: String) -> String {
        String(localized: "vote_disclosure", defaultValue: "\(a1) will see how you vote and keep that record. The published results show only an anonymous code for you.", bundle: .module)
    }

    public static var voteFinal: String {
        String(localized: "vote_final", defaultValue: "Your vote can't be changed after you cast it.", bundle: .module)
    }

    public static func voteConfirmTitle(_ a1: String) -> String {
        String(localized: "vote_confirm_title", defaultValue: "Vote “\(a1)”?", bundle: .module)
    }

    public static var voteConfirmYes: String {
        String(localized: "vote_confirm_yes", defaultValue: "Cast vote", bundle: .module)
    }

    public static var voteConfirmBack: String {
        String(localized: "vote_confirm_back", defaultValue: "Back", bundle: .module)
    }

    public static var votePasswordTitle: String {
        String(localized: "vote_password_title", defaultValue: "Confirm with your credential password", bundle: .module)
    }

    public static var votePasswordBody: String {
        String(localized: "vote_password_body", defaultValue: "Your vote is signed with your credential. Enter your credential password.", bundle: .module)
    }

    public static func voteStateSending(_ a1: String) -> String {
        String(localized: "vote_state_sending", defaultValue: "Sending your vote to \(a1)…", bundle: .module)
    }

    public static func voteStateWaiting(_ a1: String) -> String {
        String(localized: "vote_state_waiting", defaultValue: "Waiting for \(a1) to confirm. Your vote is saved on your vault and is sent again until \(a1) answers.", bundle: .module)
    }

    public static func voteStateRecorded(_ a1: String) -> String {
        String(localized: "vote_state_recorded", defaultValue: "\(a1) recorded your vote. It can't be changed.", bundle: .module)
    }

    public static var voteStateInResults: String {
        String(localized: "vote_state_in_results", defaultValue: "The published results include your vote.", bundle: .module)
    }

    public static func voteConflictAfterVerified(_ a1: String) -> String {
        String(localized: "vote_conflict_after_verified", defaultValue: "**Your vote is in the published results.** \(a1) also once showed a different vote under your code. Save the proof and show it to the organisation.", bundle: .module)
    }

    public static func voteStateUnconfirmed(_ a1: String) -> String {
        String(localized: "vote_state_unconfirmed", defaultValue: "Not confirmed. \(a1) sent no receipt for your vote, and the published results don't settle whether it counted.", bundle: .module)
    }

    public static var voteStateDidntVote: String {
        String(localized: "vote_state_didnt_vote", defaultValue: "You didn't vote in this one.", bundle: .module)
    }

    public static var voteCheckWithService: String {
        String(localized: "vote_check_with_service", defaultValue: "Check with the service", bundle: .module)
    }

    public static var voteCheckPending: String {
        String(localized: "vote_check_pending", defaultValue: "VettID will check the published results against your vote.", bundle: .module)
    }

    public static var voteCheckGaveUpSite: String {
        String(localized: "vote_check_gave_up_site", defaultValue: "VettID could not reach the votes site for 7 days, so your vote has not been checked.", bundle: .module)
    }

    public static var voteCheckGaveUpUnpublished: String {
        String(localized: "vote_check_gave_up_unpublished", defaultValue: "The results of this vote were not published within 7 days, so your vote has not been checked.", bundle: .module)
    }

    public static var voteCheckAgain: String {
        String(localized: "vote_check_again", defaultValue: "Check again", bundle: .module)
    }

    public static var voteFailedTitle: String {
        String(localized: "vote_failed_title", defaultValue: "The published results don't match your vote", bundle: .module)
    }

    public static var voteFailedBody: String {
        String(localized: "vote_failed_body", defaultValue: "You can save the proof and show it to the organisation.", bundle: .module)
    }

    public static func voteConflictBody(_ a1: String) -> String {
        String(localized: "vote_conflict_body", defaultValue: "\(a1) holds a different vote under your code than the one you cast. Save the proof and show it to the organisation.", bundle: .module)
    }

    public static func voteStateLatePending(_ a1: String) -> String {
        String(localized: "vote_state_late_pending", defaultValue: "\(a1) says the vote had closed. VettID is asking whether an earlier send arrived in time.", bundle: .module)
    }

    public static var voteRefusedLate: String {
        String(localized: "vote_refused_late", defaultValue: "The vote had closed when your vote arrived, so it was not counted.", bundle: .module)
    }

    public static func voteRefusedNotActive(_ a1: String) -> String {
        String(localized: "vote_refused_not_active", defaultValue: "\(a1) says you are no longer a member for this vote, so your vote was not counted.", bundle: .module)
    }

    public static func voteRefusedNotEligible(_ a1: String) -> String {
        String(localized: "vote_refused_not_eligible", defaultValue: "\(a1) says you were not on the list for this vote. You can save the proof and show it to the organisation.", bundle: .module)
    }

    public static func voteRefusedBadBallot(_ a1: String) -> String {
        String(localized: "vote_refused_bad_ballot", defaultValue: "\(a1) did not accept your vote. You can save the proof and show it to the organisation.", bundle: .module)
    }

    public static func voteRefusedEnded(_ a1: String) -> String {
        String(localized: "vote_refused_ended", defaultValue: "Your connection to \(a1) ended before your vote was recorded.", bundle: .module)
    }

    public static func voteNotSignedIn(_ a1: String) -> String {
        String(localized: "vote_not_signed_in", defaultValue: "Before you can vote, sign in to \(a1) once with VettID. This lets \(a1) check that your vote is yours.", bundle: .module)
    }

    public static var voteClosingSoon: String {
        String(localized: "vote_closing_soon", defaultValue: "This vote closes in less than 2 minutes. It is too late to cast your vote from this phone.", bundle: .module)
    }

    public static func voteNotOpen(_ a1: String) -> String {
        String(localized: "vote_not_open", defaultValue: "This vote opens \(a1).", bundle: .module)
    }

    public static var voteClosedBanner: String {
        String(localized: "vote_closed_banner", defaultValue: "This vote has closed.", bundle: .module)
    }

    public static var voteCheckingList: String {
        String(localized: "vote_checking_list", defaultValue: "VettID is checking this vote. It needs the list of services from votes.vettid.org. Check that this phone is online.", bundle: .module)
    }

    public static var voteCheckingSite: String {
        String(localized: "vote_checking_site", defaultValue: "VettID is checking this vote. It is waiting for the vote's documents from votes.vettid.org.", bundle: .module)
    }

    public static func voteNoConnection(_ a1: String) -> String {
        String(localized: "vote_no_connection", defaultValue: "You are no longer connected to \(a1), so you can't vote.", bundle: .module)
    }

    public static var voteResultsTitle: String {
        String(localized: "vote_results_title", defaultValue: "Results", bundle: .module)
    }

    public static func voteResultsTurnout(_ a1: Int, _ a2: Int) -> String {
        String(localized: "vote_results_turnout", defaultValue: "\(a1) of \(a2) eligible members voted.", bundle: .module)
    }

    public static func voteResultsRow(_ a1: String, _ a2: Int) -> String {
        String(localized: "vote_results_row", defaultValue: "\(a1): \(a2)", bundle: .module)
    }

    public static func voteResultsUnhandled(_ a1: Int, _ a2: String) -> String {
        String(localized: "vote_results_unhandled", defaultValue: "\(a1) messages sent to \(a2) during the vote were not handled; any vote among them was not counted.", bundle: .module)
    }

    public static func voteQuorumMet(_ a1: Int, _ a2: Int) -> String {
        String(localized: "vote_quorum_met", defaultValue: "Enough votes were cast: \(a1), and the service asked for at least \(a2).", bundle: .module)
    }

    public static func voteQuorumNotMet(_ a1: Int, _ a2: Int) -> String {
        String(localized: "vote_quorum_not_met", defaultValue: "Not enough votes were cast: \(a1), and the service asked for at least \(a2).", bundle: .module)
    }

    public static var voteSaveProof: String {
        String(localized: "vote_save_proof", defaultValue: "Save the proof", bundle: .module)
    }

    public static var voteSaveProofWarning: String {
        String(localized: "vote_save_proof_warning", defaultValue: "The file shows how you voted. Keep it private, and share it only with the organisation.", bundle: .module)
    }

    public static var voteRejectedTitle: String {
        String(localized: "vote_rejected_title", defaultValue: "VettID set this vote aside", bundle: .module)
    }

    public static var voteCheckingTrust: String {
        String(localized: "vote_checking_trust", defaultValue: "VettID can't finish checking this vote yet: its list of trusted logs may be out of date. Update VettID if this lasts.", bundle: .module)
    }

    public static var voteCheckingClock: String {
        String(localized: "vote_checking_clock", defaultValue: "VettID can't finish checking this vote yet because of a time check on VettID's side. It will try again.", bundle: .module)
    }

    public static func voteCheckingRestore(_ a1: String) -> String {
        String(localized: "vote_checking_restore", defaultValue: "VettID is asking \(a1) what it recorded for you before you can vote.", bundle: .module)
    }

    public static var voteNotPublished: String {
        String(localized: "vote_not_published", defaultValue: "This vote is not on the public site yet. You can still vote: VettID will compare it with the public copy when it appears.", bundle: .module)
    }

    public static var voteSiteUnreachable: String {
        String(localized: "vote_site_unreachable", defaultValue: "VettID could not reach the votes site to compare this vote with the public copy. You can still vote: VettID will compare it later.", bundle: .module)
    }

    public static func voteDropped(_ a1: String, _ a2: Int) -> String {
        String(localized: "vote_dropped", defaultValue: "\(a1) has more votes under way than your vault can keep, so \(a2) were not kept.", bundle: .module)
    }

    public static func voteProblems(_ a1: String, _ a2: Int) -> String {
        String(localized: "vote_problems", defaultValue: "\(a1) has \(a2) unresolved vote problems. Save the proof of each and release them to receive new votes from \(a1).", bundle: .module)
    }

    public static var voteSiteMismatch: String {
        String(localized: "vote_site_mismatch", defaultValue: "The vote you received differs from the one published on the public site, so you can't vote in it. You can save the proof.", bundle: .module)
    }

    public static var voteSiteMismatchAfter: String {
        String(localized: "vote_site_mismatch_after", defaultValue: "The vote you voted on differs from the one published on the public site, so your vote may not count. Save the proof and show it to the organisation.", bundle: .module)
    }

    public static var voteUnpublished: String {
        String(localized: "vote_unpublished", defaultValue: "This vote was never published on the public site. Your vote may not count. Save the proof.", bundle: .module)
    }

    public static var voteNotListedLate: String {
        String(localized: "vote_not_listed_late", defaultValue: "This vote is still not on the public site, which is unusual. You can vote, but keep the proof.", bundle: .module)
    }

    public static var voteRestoreTitle: String {
        String(localized: "vote_restore_title", defaultValue: "Is this your vote?", bundle: .module)
    }

    public static func voteRestoreBody(_ a1: String, _ a2: String, _ a3: String) -> String {
        String(localized: "vote_restore_body", defaultValue: "\(a1) says it recorded this vote for you: “\(a2)” on “\(a3)”.", bundle: .module)
    }

    public static var voteRestoreYes: String {
        String(localized: "vote_restore_yes", defaultValue: "Yes, it's mine", bundle: .module)
    }

    public static var voteRestoreNo: String {
        String(localized: "vote_restore_no", defaultValue: "No, it isn't mine", bundle: .module)
    }

    public static var voteReconnectTitle: String {
        String(localized: "vote_reconnect_title", defaultValue: "Connect again to vote", bundle: .module)
    }

    public static func voteReconnectBody(_ a1: String) -> String {
        String(localized: "vote_reconnect_body", defaultValue: "\(a1) is registered with VettID as a service. This connection was made before it said it was a service, so it can't take part in votes. Remove it and connect again from a new invitation from \(a1).", bundle: .module)
    }

    public static var voteReconnectOpen: String {
        String(localized: "vote_reconnect_open", defaultValue: "Open the connection", bundle: .module)
    }

    public static func voteConnectionRow(_ a1: String) -> String {
        String(localized: "vote_connection_row", defaultValue: "Votes from \(a1)", bundle: .module)
    }

    public static func voteRemoveWarning(_ a1: String) -> String {
        String(localized: "vote_remove_warning", defaultValue: "You have a vote with \(a1) that isn't finished. If you remove this connection you can't vote in it.", bundle: .module)
    }

    public static var voteCheckResultsProblem: String {
        String(localized: "vote_check_results_problem", defaultValue: "VettID could not check the published results of this vote yet. They may be incomplete or not valid. It will try again.", bundle: .module)
    }

    public static var voteCheckGaveUp: String {
        String(localized: "vote_check_gave_up", defaultValue: "VettID could not check the results of this vote within 7 days, so your vote has not been checked.", bundle: .module)
    }

    public static var voteCheckingOther: String {
        String(localized: "vote_checking_other", defaultValue: "VettID is still checking this vote. You can vote when the check is done.", bundle: .module)
    }

    public static var voteCannotCastOther: String {
        String(localized: "vote_cannot_cast_other", defaultValue: "You can't vote in this one right now.", bundle: .module)
    }

    public static func voteDisputedBody(_ a1: String) -> String {
        String(localized: "vote_disputed_body", defaultValue: "\(a1) holds a vote under your code that you said is not yours. Save the proof and show it to the organisation.", bundle: .module)
    }

    public static var voteRejectedSignature: String {
        String(localized: "vote_rejected_signature", defaultValue: "The service's signature on this vote did not check out.", bundle: .module)
    }

    public static var voteRejectedAnchor: String {
        String(localized: "vote_rejected_anchor", defaultValue: "The public record of this vote did not check out.", bundle: .module)
    }

    public static var voteRejectedRecord: String {
        String(localized: "vote_rejected_record", defaultValue: "The list of members for this vote did not check out.", bundle: .module)
    }

    public static var voteRejectedOther: String {
        String(localized: "vote_rejected_other", defaultValue: "This vote could not be read as a valid vote from the service.", bundle: .module)
    }

    public static var voteCheckSiteUnreachableNow: String {
        String(localized: "vote_check_site_unreachable_now", defaultValue: "VettID could not reach the votes site just now. It will try again.", bundle: .module)
    }

    public static var voteCheckNotPublishedNow: String {
        String(localized: "vote_check_not_published_now", defaultValue: "The results of this vote are not on the votes site yet. VettID will try again.", bundle: .module)
    }

    public static var voteServiceFallback: String {
        String(localized: "vote_service_fallback", defaultValue: "The service", bundle: .module)
    }

    public static func voteYourChoice(_ a1: String) -> String {
        String(localized: "vote_your_choice", defaultValue: "Your choice: \(a1)", bundle: .module)
    }

    public static var voteServiceLabel: String {
        String(localized: "vote_service_label", defaultValue: "Service", bundle: .module)
    }

    public static var voteNameByService: String {
        String(localized: "vote_name_by_service", defaultValue: "Name given by the service", bundle: .module)
    }

    public static func voteClosesLine(_ a1: String) -> String {
        String(localized: "vote_closes_line", defaultValue: "Closes \(a1)", bundle: .module)
    }

    public static func voteRowDescription(_ a1: String, _ a2: String, _ a3: String) -> String {
        String(localized: "vote_row_description", defaultValue: "\(a1), from the service \(a2), \(a3)", bundle: .module)
    }

    public static var votesEmptyTitle: String {
        String(localized: "votes_empty_title", defaultValue: "No votes", bundle: .module)
    }

    public static var votesEmptyBody: String {
        String(localized: "votes_empty_body", defaultValue: "Votes from services you are connected to appear here.", bundle: .module)
    }

    public static var votesErrorTitle: String {
        String(localized: "votes_error_title", defaultValue: "Could not load your votes", bundle: .module)
    }

    public static var voteErrorTitle: String {
        String(localized: "vote_error_title", defaultValue: "Could not load this vote", bundle: .module)
    }

    public static var voteGoneTitle: String {
        String(localized: "vote_gone_title", defaultValue: "This vote is no longer here", bundle: .module)
    }

    public static var votesRetry: String {
        String(localized: "votes_retry", defaultValue: "Try again", bundle: .module)
    }

    public static var votePasswordLabel: String {
        String(localized: "vote_password_label", defaultValue: "Credential password", bundle: .module)
    }

    public static var votePasswordConfirm: String {
        String(localized: "vote_password_confirm", defaultValue: "Confirm", bundle: .module)
    }

    public static var voteCastFailedTitle: String {
        String(localized: "vote_cast_failed_title", defaultValue: "Your vote was not sent", bundle: .module)
    }

    public static var voteCastUnknownTitle: String {
        String(localized: "vote_cast_unknown_title", defaultValue: "VettID got no answer", bundle: .module)
    }

    public static var voteCastUnanswered: String {
        String(localized: "vote_cast_unanswered", defaultValue: "Your vote may have been sent. This screen shows it as sent once VettID knows. If it does not, you can cast again. If your first vote did arrive, it is the one that counts: a vote can't be changed.", bundle: .module)
    }

    public static func voteAlreadyVoted(_ a1: String) -> String {
        String(localized: "vote_already_voted", defaultValue: "You had already voted: \(a1). Your vote can't be changed.", bundle: .module)
    }

    public static var voteAlreadyVotedAny: String {
        String(localized: "vote_already_voted_any", defaultValue: "You had already voted. Your vote can't be changed.", bundle: .module)
    }

    public static var voteWindowNotClosedTitle: String {
        String(localized: "vote_window_not_closed_title", defaultValue: "The unlock window may still be open", bundle: .module)
    }

    public static var voteWindowNotClosedPlain: String {
        String(localized: "vote_window_not_closed_plain", defaultValue: "VettID could not close the credential unlock window after your vote. It closes by itself.", bundle: .module)
    }

    public static var voteWindowCloseNow: String {
        String(localized: "vote_window_close_now", defaultValue: "Close it now", bundle: .module)
    }

    public static var voteCheckResultsTooLarge: String {
        String(localized: "vote_check_results_too_large", defaultValue: "VettID can't check the published results of this vote: they are larger than your vault accepts. They may not be valid.", bundle: .module)
    }

    public static var voteProofSaved: String {
        String(localized: "vote_proof_saved", defaultValue: "The proof was saved.", bundle: .module)
    }

    public static var voteProofFailed: String {
        String(localized: "vote_proof_failed", defaultValue: "The proof could not be saved. Try again.", bundle: .module)
    }

    public static var voteProofSave: String {
        String(localized: "vote_proof_save", defaultValue: "Save", bundle: .module)
    }

    public static var voteRelease: String {
        String(localized: "vote_release", defaultValue: "Release", bundle: .module)
    }

    public static var voteReleaseTitle: String {
        String(localized: "vote_release_title", defaultValue: "Release this vote record?", bundle: .module)
    }

    public static func voteReleaseBody(_ a1: String) -> String {
        String(localized: "vote_release_body", defaultValue: "This lets your vault keep new votes from \(a1). Every signed item that is not on the public site stays on your vault. Nothing is sent anywhere. Enter your vault PIN.", bundle: .module)
    }

    public static var voteReleasePin: String {
        String(localized: "vote_release_pin", defaultValue: "Vault PIN", bundle: .module)
    }

    public static var voteReleaseNotSaved: String {
        String(localized: "vote_release_not_saved", defaultValue: "Save the proof first: the record can be released only after it was saved.", bundle: .module)
    }

    public static var voteReleased: String {
        String(localized: "vote_released", defaultValue: "The vote record was released.", bundle: .module)
    }

    /// "Cancel" (chosen; not in the spec: vettid-android uses its shared `core_ui_cancel`).
    public static var voteCancel: String {
        String(localized: "vote_cancel", defaultValue: "Cancel", bundle: .module)
    }

    /// The unlock window notice with the vault's unlock time in whole minutes (plural).
    public static func voteWindowNotClosed(minutes: Int) -> String {
        String(
            localized: "vote_window_not_closed",
            defaultValue: "VettID could not close the credential unlock window after your vote. It closes by itself once it has not been used for \(minutes) minutes.",
            bundle: .module
        )
    }
}
