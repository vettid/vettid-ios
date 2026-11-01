#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VettIDConnections
@testable import VettIDConnectionsUI
@testable import VettIDData
import VettIDUI

// Expected texts stay on one line each.
// swiftlint:disable line_length

/// The votes on a connection's page (ANDROID-PLAN 0.1.102 "Votes", screens 8 and 9): the approved words, word for word, and
/// the page rendering with each. Mirrors vettid-android `ConnectionVotesTest`'s screen cases.
@MainActor
@Suite struct ConnectionVotesScreenTests {
    @Test func theApprovedTextsAreWordForWord() {
        #expect(ConnectStrings.voteRow("Example") == "Votes from Example")
        #expect(ConnectStrings.voteRemoveWarning("Example") == "You have a vote with Example that isn't finished. If you remove this connection you can't vote in it.")
        #expect(ConnectStrings.voteReconnectTitle == "Connect again to vote")
        #expect(ConnectStrings.voteReconnectBody("Example") == "Example is registered with VettID as a service. This connection was made before it said it was a service, so it can't take part in votes. Remove it and connect again from a new invitation from Example.")
    }

    private func page(_ votes: ConnectionVotes, service: Bool, confirm: DetailConfirm? = nil, actions: DetailActions = DetailActions()) -> CGFloat {
        var c = ConnectionInfo(id: "c1", name: "Example Cooperative", state: .active)
        c.firstName = "Example"
        c.lastName = "Cooperative"
        c.isService = service
        var s = ConnectionDetailState(connectionID: "c1")
        s.connection = c
        s.loading = false
        s.votes = votes
        s.confirm = confirm
        let view = ConnectionDetailScreen(state: s, actions: actions)
        return UIHostingController(rootView: view.vettIDTheme(.light)).sizeThatFits(in: CGSize(width: 390, height: 20_000)).height
    }

    @Test func thePageRendersWithEachVotesState() {
        var actions = DetailActions()
        actions.onOpenVotes = {}
        for (votes, service) in [
            (ConnectionVotes(), true), (ConnectionVotes(count: 2), true), (ConnectionVotes(count: 1, unfinished: true), true),
            (ConnectionVotes(reconnect: true), false),
        ] {
            #expect(page(votes, service: service, actions: actions) > 0)
        }
        #expect(page(ConnectionVotes(count: 1, unfinished: true), service: true, confirm: .remove, actions: actions) > 0)
    }

    @Test func theVotesRowAndTheReconnectCardAddToThePage() {
        var actions = DetailActions()
        actions.onOpenVotes = {}
        let none = page(ConnectionVotes(), service: true, actions: actions)
        #expect(page(ConnectionVotes(count: 2), service: true, actions: actions) > none)
        // Without a hook (the app has no Votes) there is no row; a person connection never gets the row.
        #expect(page(ConnectionVotes(count: 2), service: true) == none)
        #expect(page(ConnectionVotes(count: 2), service: false, actions: actions) == none)
        #expect(page(ConnectionVotes(reconnect: true), service: false, actions: actions) > none)
    }
}
// swiftlint:enable line_length
#endif
