import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDConnections

/// A connection's detail and Votes (ANDROID-PLAN 0.1.102 "Votes", screens 8 and 9). Mirrors vettid-android
/// `ConnectionVotesTest`'s view-model cases.
@MainActor
@Suite struct ConnectionVotesTests {
    let fake = FakeConnections()
    let votes = FakeVotes()

    private func vote(_ conn: String, _ id: String, state: VoteState = .open, ballot: VoteBallot? = nil) -> VoteSummary {
        VoteSummary(proposalID: id, connectionID: conn, title: "T\(id)", state: state, ballot: ballot)
    }

    private func service(_ id: String = "c1") -> ConnectionInfo {
        var c = Samples.active(id)
        c.isService = true
        return c
    }

    private func model(_ id: String = "c1") async -> ConnectionDetailViewModel {
        let m = ConnectionDetailViewModel(connectionID: id, connections: fake, votes: votes)
        await m.settle()
        return m
    }

    @Test func aServiceConnectionKnowsItsVotesAndWhetherOneIsUnfinished() async {
        fake.connections = [service()]
        votes.votes = [vote("c1", "A"), vote("c2", "B")]
        let m = await model()
        #expect(m.state.votes.count == 1)
        // An open vote is unfinished.
        #expect(m.state.votes.unfinished)
        votes.votes = [vote("c1", "A", state: .closed, ballot: VoteBallot(state: .recorded))]
        #expect(!m.state.votes.unfinished)
        // A ballot still being sent is unfinished too.
        votes.votes = [vote("c1", "A", state: .closed, ballot: VoteBallot(state: .sending))]
        #expect(m.state.votes.unfinished)
    }

    @Test func aPersonConnectionTheServiceListNamesIsToBeConnectedAgain() async {
        fake.connections = [Samples.active("c9")]
        votes.reconnect = [ReconnectEntry(connectionID: "c9", serviceID: "svc", name: "Old Cooperative")]
        let m = await model("c9")
        #expect(m.state.votes.reconnect)
        // The app changes nothing about the connection on its own.
        #expect(m.state.connection?.isService == false && fake.calls == ["connection"])
    }

    @Test func withoutVotesThereIsNothing() async {
        fake.connections = [service()]
        let withNone = await model()
        #expect(withNone.state.votes == ConnectionVotes())
        let m = ConnectionDetailViewModel(connectionID: "c1", connections: fake)
        await m.settle()
        #expect(m.state.votes == ConnectionVotes())
    }

    @Test func aGoneConnectionShowsNoVotes() async {
        let m = await model("nope")
        votes.votes = [vote("nope", "A")]
        #expect(m.state.gone && m.state.votes == ConnectionVotes())
    }
}
