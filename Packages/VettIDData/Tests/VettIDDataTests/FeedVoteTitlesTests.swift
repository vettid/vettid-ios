import Foundation
import Testing
@testable import VettIDData
import VettIDVault

// Fixtures and expected texts stay on one line each.
// swiftlint:disable line_length

/// The vote items of the feed (ANDROID-PLAN 0.1.102 "Votes", VAULT-MESSAGING 0.81.0 §10.19.7): the owner-approved titles and
/// second lines word for word, the vote named by the pair, the target, and no choice anywhere. Mirrors vettid-android
/// `FeedVoteItemsTest`.
@Suite struct FeedVoteTitlesTests {
    static func item(_ kind: String, connection: String? = "c1", ref: String? = "p1") -> FeedItem {
        FeedItem(itemID: "i", seq: 1, kind: kind, at: "2026-10-31T12:00:00Z", status: "active", priority: "normal", connectionID: connection, ref: ref)
    }

    static let names: FeedNames = {
        var service = ConnectionInfo(id: "c1", name: "", state: .active)
        service.firstName = "Example"
        service.lastName = "Cooperative"
        let vote = VoteSummary(proposalID: "p1", connectionID: "c1", title: "Adopt the budget", state: .open)
        let other = VoteSummary(proposalID: "p1", connectionID: "c2", title: "Another service's vote", state: .open)
        return FeedNames(connections: [service], approvals: [], votes: [vote, other])
    }()

    @Test func theTitlesAreTheApprovedWords() {
        #expect(FeedKinds.title(Self.item("vote.open"), Self.names) == "A new vote")
        #expect(FeedKinds.title(Self.item("vote.closing"), Self.names) == "A vote closes soon")
        #expect(FeedKinds.title(Self.item("vote.result"), Self.names) == "Vote results are out")
        #expect(FeedKinds.title(Self.item("vote.problem"), Self.names) == "Check your vote")
        // With names only (a notification without details) the same words: nothing in them is a detail.
        #expect(FeedKinds.title(Self.item("vote.open"), Self.names, details: false) == "A new vote")
    }

    @Test func theSecondLineIsTheServiceAndTheVotesTitle() {
        let service = "\u{2068}Example Cooperative\u{2069}"
        for kind in ["vote.open", "vote.closing", "vote.result"] {
            #expect(FeedKinds.supporting(Self.item(kind), Self.names) == "\(service): \u{2068}Adopt the budget\u{2069}", "\(kind)")
        }
        #expect(FeedKinds.supporting(Self.item("vote.problem"), Self.names) == "Something about your vote needs your attention.")
    }

    @Test func theTitleIsLookedUpByThePairNeverTheProposalIdAlone() {
        // The same proposal id from another service is another vote.
        #expect(FeedKinds.supporting(Self.item("vote.open", connection: "c2"), Self.names) == "Removed connection: \u{2068}Another service's vote\u{2069}")
        let c2 = FeedNames(connections: [], approvals: [], votes: [VoteSummary(proposalID: "p1", connectionID: "c2", title: "Other", state: .open)])
        #expect(FeedKinds.supporting(Self.item("vote.open", connection: "c2"), c2)?.hasSuffix(": \u{2068}Other\u{2069}") == true)
        #expect(VoteTitles.key("c1", "p1") == "c1/p1" && VoteTitles.key(nil, nil) == "/")
    }

    @Test func withoutTheVotesTitleTheServiceAloneIsTheSecondLine() {
        #expect(FeedKinds.supporting(Self.item("vote.open", ref: "unknown"), Self.names) == "\u{2068}Example Cooperative\u{2069}")
        #expect(FeedKinds.supporting(Self.item("vote.open", connection: nil, ref: nil), FeedNames()) == "Someone")
    }

    @Test func aTitleThatShowsNothingIsLeftOut() {
        let blank = FeedNames(connections: [], approvals: [], votes: [VoteSummary(proposalID: "p1", connectionID: "c1", title: "", state: .open)])
        #expect(blank.votes.isEmpty)
    }

    @Test func theTargetIsTheVoteOrTheList() {
        #expect(FeedKinds.target(Self.item("vote.open")) == .vote(connectionID: "c1", proposalID: "p1"))
        #expect(FeedKinds.target(Self.item("vote.problem", ref: "p9")) == .vote(connectionID: "c1", proposalID: "p9"))
        #expect(FeedKinds.target(Self.item("vote.closing", ref: nil)) == .voteList)
        #expect(FeedKinds.target(Self.item("vote.result", ref: "")) == .voteList)
        #expect(FeedKinds.target(Self.item("vote.open", connection: nil)) == .voteList)
    }

    @Test func theKindsAreKnownAndShownNeverUnknownOrLater() {
        for kind in ["vote.open", "vote.closing", "vote.result", "vote.problem"] {
            #expect(FeedKinds.isKnown(kind) && FeedKinds.classify(kind) == .shown && !FeedKinds.isHidden(Self.item(kind)), "\(kind)")
            #expect(!FeedKinds.isAsk(kind), "\(kind)")
        }
    }

    /// History's Connections filter holds the vote entries (0.1.102), and so a vote item's icon.
    @Test func voteEntriesAreTheServiceConnectionsInHistory() {
        #expect(AuditCategory.of("vote.cast") == .connections && AuditCategory.of("vote.check_ok") == .connections)
        #expect(AuditCategory.connections.prefixes.contains("vote"))
    }
}
// swiftlint:enable line_length
