import Foundation
import Testing
import VettIDData
@testable import VettIDHistory

// Expected texts stay on one line each.
// swiftlint:disable line_length

/// History's vote titles (ANDROID-PLAN 0.1.102 "Votes"): the owner-approved words, the vote's title from the list in memory,
/// "a vote" without it, never a choice. Mirrors vettid-android `HistoryVoteTitlesTest`.
@Suite struct HistoryVoteTitlesTests {
    private func title(_ kind: String, _ ref: String? = "P1", names: EntryNames = EntryNames(connection: "Example", vote: "Adopt the budget")) -> String {
        HistoryText.title(kind, ref, names: names, isolate: false)
    }

    @Test func theTitlesReadAsApproved() {
        #expect(title("vote.cast") == "You cast a vote: “Adopt the budget”")
        #expect(title("vote.recorded") == "Example recorded your vote: “Adopt the budget”")
        #expect(title("vote.conflict") == "Example holds a different vote under your code: “Adopt the budget”")
        #expect(title("vote.receipt_rejected") == "A receipt for your vote could not be checked: “Adopt the budget”")
        #expect(title("vote.extended", "P1:1") == "The closing time of “Adopt the budget” was extended")
        #expect(title("vote.extension_rejected", "P1:late") == "A change of closing time was not accepted: “Adopt the budget”")
        #expect(title("vote.proposal_rejected", "P1:record") == "A vote from Example could not be checked and was set aside")
        #expect(title("vote.list_rejected", nil) == "The list of services was not accepted")
        #expect(title("vote.check_ok") == "The published results include your vote: “Adopt the budget”")
        #expect(title("vote.check_unconfirmed") == "Your vote could not be confirmed in the published results: “Adopt the budget”")
        #expect(title("vote.check_failed", "P1:row_mismatch") == "The published results do not match your vote: “Adopt the budget”")
        #expect(title("vote.check_gave_up") == "The results of “Adopt the budget” could not be checked")
        #expect(title("vote.released") == "Vote record released: “Adopt the budget”")
    }

    @Test func aRefusalNamesTheReasonInWords() {
        #expect(title("vote.refused", "P1:closed") == "Example did not accept your vote: “Adopt the budget” (the vote had closed)")
        #expect(title("vote.refused", "P1:late") == "Example did not accept your vote: “Adopt the budget” (the vote had closed)")
        #expect(title("vote.refused", "P1:not_active") == "Example did not accept your vote: “Adopt the budget” (you are no longer a member)")
        #expect(title("vote.refused", "P1:not_eligible") == "Example did not accept your vote: “Adopt the budget” (you were not on the list)")
        #expect(title("vote.refused", "P1:connection_ended") == "Example did not accept your vote: “Adopt the budget” (the connection ended)")
        #expect(title("vote.refused", "P1:something_new") == "Example did not accept your vote: “Adopt the budget” (not accepted)")
    }

    @Test func theProposalConflictsReadBySuffix() {
        #expect(title("vote.proposal_conflict", "P1:mismatch") == "The vote from Example differs from the one published on the public site")
        #expect(title("vote.proposal_conflict", "P1:not_listed") == "A vote from Example is not on the public site yet")
        #expect(title("vote.proposal_conflict", "P1:unpublished") == "A vote from Example was never published on the public site")
        #expect(title("vote.proposal_conflict", "P1") == "Example sent two different versions of one vote")
    }

    @Test func withoutTheVotesTitleOrTheServiceTheTitleSaysAVoteOrAService() {
        let none = EntryNames()
        #expect(title("vote.cast", names: none) == "You cast a vote")
        #expect(title("vote.recorded", names: none) == "A service recorded your vote")
        #expect(title("vote.check_gave_up", names: none) == "The results of a vote could not be checked")
        #expect(title("vote.proposal_rejected", names: none) == "A vote could not be checked and was set aside")
        #expect(title("vote.refused", "P1:closed", names: none) == "A service did not accept your vote (the vote had closed)")
        #expect(title("vote.proposal_conflict", "P1:mismatch", names: none) == "A vote differs from the one published on the public site")
        #expect(title("vote.proposal_conflict", "P1", names: none) == "A service sent two different versions of one vote")
    }

    @Test func theNamesAreIsolatedInARowAndPlainInAFile() {
        let names = EntryNames(connection: "Example", vote: "Adopt the budget")
        #expect(HistoryText.title("vote.recorded", "P1", names: names) == "\u{2068}Example\u{2069} recorded your vote: “\u{2068}Adopt the budget\u{2069}”")
        #expect(HistoryText.title("vote.recorded", "P1", names: names, isolate: false) == "Example recorded your vote: “Adopt the budget”")
    }

    @Test func aVoteMessageTheVaultIgnoredIsOneTitle() {
        for k in ["drop.vote_malformed", "drop.vote_limit", "drop.vote_not_service"] {
            #expect(title(k, nil) == "A vote message was ignored", "\(k)")
        }
    }

    @Test func theProposalIdComesFromTheRefAndVoteEntriesAreTheConnectionsCategory() {
        #expect(AuditKinds.voteOf("vote.refused", "P1:closed") == "P1")
        #expect(AuditKinds.voteOf("vote.cast", "P1") == "P1")
        #expect(AuditKinds.voteOf("item.added", "P1") == nil)
        #expect(AuditKinds.voteOf("vote.cast", "") == nil && AuditKinds.voteOf("vote.cast", nil) == nil)
        for k in ["vote.cast", "vote.recorded", "vote.check_ok", "vote.proposal_conflict", "vote.list_rejected"] {
            #expect(AuditCategory.of(k) == .connections, "\(k)")
        }
        #expect(AuditCategory.of("drop.vote_limit") == .dropped)
    }

    @Test func theVoteTitleIsLookedUpByThePairNeverTheProposalIdAlone() {
        let titles = [VoteTitles.key("c1", "P1"): "One", VoteTitles.key("c2", "P1"): "Two", VoteTitles.key("c3", "P3"): ""]
        #expect(AuditKinds.voteTitle("vote.cast", "P1", connectionID: "c1", in: titles) == "One")
        #expect(AuditKinds.voteTitle("vote.cast", "P1", connectionID: "c2", in: titles) == "Two")
        #expect(AuditKinds.voteTitle("vote.cast", "P1", connectionID: "c9", in: titles) == nil)
        #expect(AuditKinds.voteTitle("vote.cast", "P3", connectionID: "c3", in: titles) == nil, "an empty title is not a title")
        #expect(AuditKinds.voteTitle("vote.cast", "P1", connectionID: "c1", in: nil) == nil)
        #expect(AuditKinds.voteTitle("item.added", "P1", connectionID: "c1", in: titles) == nil)
    }

    @Test func noVoteTitleCarriesAChoiceAndAnUnknownVoteKindIsShownAsItIs() {
        #expect(!title("vote.cast").contains("yes"))
        #expect(AuditKinds.title("vote.disputed", "P1") == .unknown("vote.disputed"))
    }

    /// The approved texts, key by key, in the package's table.
    @Test func theTextsOfTheTableAreWordForWord() {
        let table: [(String, String)] = [
            ("history_kind_vote_cast", "You cast a vote: “%@”"), ("history_kind_vote_cast_any", "You cast a vote"),
            ("history_kind_vote_recorded", "%@ recorded your vote: “%@”"), ("history_kind_vote_recorded_any", "%@ recorded your vote"),
            ("history_kind_vote_refused", "%@ did not accept your vote: “%@” (%@)"), ("history_kind_vote_refused_any", "%@ did not accept your vote (%@)"),
            ("history_kind_vote_conflict_any", "%@ holds a different vote under your code"),
            ("history_kind_vote_receipt_rejected_any", "A receipt for your vote could not be checked"),
            ("history_kind_vote_extended_any", "The closing time of a vote was extended"),
            ("history_kind_vote_extension_rejected_any", "A change of closing time was not accepted"),
            ("history_kind_vote_site_mismatch", "The vote from %@ differs from the one published on the public site"),
            ("history_kind_vote_not_listed_any", "A vote is not on the public site yet"),
            ("history_kind_vote_unpublished_any", "A vote was never published on the public site"),
            ("history_kind_vote_two_versions", "%@ sent two different versions of one vote"),
            ("history_kind_vote_check_ok_any", "The published results include your vote"),
            ("history_kind_vote_check_unconfirmed_any", "Your vote could not be confirmed in the published results"),
            ("history_kind_vote_check_failed_any", "The published results do not match your vote"),
            ("history_kind_vote_released", "Vote record released: “%@”"), ("history_kind_vote_ignored", "A vote message was ignored"),
            ("history_vote_a_service", "A service"), ("history_vote_reason_closed", "the vote had closed"),
            ("history_vote_reason_not_active", "you are no longer a member"), ("history_vote_reason_not_eligible", "you were not on the list"),
            ("history_vote_reason_connection_ended", "the connection ended"), ("history_vote_reason_not_accepted", "not accepted"),
        ]
        for (key, want) in table {
            #expect(HistoryKindTexts.english[key] == want, "\(key)")
            #expect(HistoryKindTexts.text(key) == want, "\(key)")
        }
        let voteKeys = HistoryKindTexts.english.keys.filter { $0.hasPrefix("history_kind_vote") || $0.hasPrefix("history_vote_") }
        #expect(voteKeys.count == 42)
    }
}
// swiftlint:enable line_length
