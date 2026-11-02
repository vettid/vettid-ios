#if os(iOS)
import SwiftUI
import VettIDData
import VettIDShell
import VettIDVotes
import VettIDVotesUI

/// The Votes screens over the shell (vettid-android's `votesDestination`): a vote by the pair (connection, proposal), and a
/// service's votes from its page.
extension AppShell {
    /// A vote and a service's votes over the Votes list or a connection's page (vettid-android's `votesDestination`).
    @ViewBuilder func votesDetail(_ route: ShellRoute) -> some View {
        if let votes, let connections {
            switch route {
            case .vote(let connectionID, let proposalID):
                VoteRoute(
                    VoteKey(connectionID: connectionID, proposalID: proposalID), votes: votes, connections: connections,
                    ownerChecks: ownerChecks, host: votesHost
                )
            case .connectionVotes(let id):
                ConnectionVotesRoute(id, votes: votes, connections: connections, ownerChecks: ownerChecks, host: votesHost)
            default:
                EmptyView()
            }
        }
    }

    /// Where the Votes screens go (vettid-android `VotesHost`).
    var votesHost: VotesHost {
        let model = model
        var h = VotesHost()
        h.onOpen = { model.openVote($0.connectionID, $0.proposalID) }
        h.onOpenConnection = { model.push(.connection($0)) }
        h.onBack = { model.pop() }
        return h
    }
}
#endif
