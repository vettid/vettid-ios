import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVotes

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The Votes list (ANDROID-PLAN 0.1.102 §4 "Votes", screen 1; IOS-PLAN §4.16): the sections, the notices, one service's
/// votes, a read cut off by a lock, and the unlock window notice. Mirrors vettid-android `VotesViewModelTest`.
@MainActor
@Suite struct VotesViewModelTests {
    let fake = FakeVotes()
    let connections = FakeConnections()

    init() { connections.connections = [Samples.service("c1", name: "Example Org"), Samples.service("c2", name: "Other Org")] }

    func list(only: String? = nil) async -> VotesViewModel {
        let m = VotesViewModel(repo: fake, connections: connections, only: only)
        m.refresh()
        await m.settle()
        return m
    }

    @Test func theListHasOpenAndClosedSectionsAndTheServicesNames() async {
        fake.votes = [Samples.open(), Samples.closed(VoteBallot(state: .recorded)), Samples.open("c2", "p2", canCast: false, state: .upcoming)]
        let m = await list()
        #expect(m.state.open.map(\.proposalID) == ["p1", "p2"] && m.state.closed.count == 1)
        #expect(m.state.services == ["c1": "Example Org", "c2": "Other Org"] && !m.state.loading && !m.state.empty)
    }

    @Test func theListNeverShowsAnEmptyScreenOfNothingBeforeItIsRead() async {
        fake.load = .notLoaded
        let m = VotesViewModel(repo: fake, connections: connections)
        #expect(m.state.loading && !m.state.empty)
        fake.load = .loaded
        #expect(m.state.empty && !m.state.loading)
    }

    @Test func aConnectionToConnectAgainIsNotEmpty() async {
        fake.reconnect = [ReconnectEntry(connectionID: "c1", serviceID: "s", name: "Example Org")]
        let m = await list()
        #expect(!m.state.empty && m.state.reconnect.count == 1)
    }

    @Test func aFailedReadIsToldAndTriedAgain() async {
        fake.fail["refresh"] = VaultFailure(.network)
        let m = await list()
        #expect(m.state.error == .network)
        m.refresh()
        await m.settle()
        #expect(m.state.error == nil)
    }

    /// Owner behaviour 4: a read cut off by a lock or by the app leaving is silent.
    @Test func aReadCutOffIsSilent() async {
        fake.failError["refresh"] = CancellationError()
        let m = await list()
        #expect(m.state.error == nil)
    }

    @Test func oneServicesVotesAndNoticesOnly() async {
        fake.votes = [Samples.open("c1", "p1"), Samples.open("c2", "p2")]
        fake.dropped = [DroppedNotice(connectionID: "c1", count: 2), DroppedNotice(connectionID: "c2", count: 1)]
        fake.problems = [ProblemsNotice(connectionID: "c2", count: 3)]
        fake.reconnect = [ReconnectEntry(connectionID: "c2", serviceID: "s", name: "Other Org")]
        let m = await list(only: "c2")
        #expect(m.state.votes.map(\.proposalID) == ["p2"] && m.state.dropped.map(\.connectionID) == ["c2"])
        #expect(m.state.problems.count == 1 && m.state.reconnect.count == 1)
    }

    @Test func aShownDroppedNoticeIsAcknowledgedOnce() async {
        fake.dropped = [DroppedNotice(connectionID: "c1", count: 2)]
        let m = await list()
        m.noticesShown(["c1"])
        #expect(fake.acknowledged == [["c1"]] && m.state.dropped.isEmpty)
    }

    /// Owner behaviour 1: the notice is the repository's, so it shows on the list too, and **Close it now** works there.
    @Test func theWindowNoticeShowsOnTheListAndCloseItNowWorksFromThere() async {
        fake.windowNotClosed = WindowNotClosed(ttlSeconds: 300)
        let m = await list()
        #expect(m.state.windowNotClosed == WindowNotClosed(ttlSeconds: 300) && !m.state.empty)
        fake.fail["closeWindowNow"] = VaultFailure(.network)
        m.closeWindowNow()
        await m.settle()
        #expect(m.state.windowNotClosed != nil && m.state.windowCloseProblem?.kind == .network)
        m.closeWindowNow()
        await m.settle()
        #expect(m.state.windowNotClosed == nil && m.state.windowCloseProblem == nil)
    }

    @Test func closeItNowCutOffIsSilent() async {
        fake.windowNotClosed = WindowNotClosed(ttlSeconds: 300)
        let m = await list()
        fake.failError["closeWindowNow"] = CancellationError()
        m.closeWindowNow()
        await m.settle()
        #expect(m.state.windowCloseProblem == nil && !m.state.windowClosing && m.state.windowNotClosed != nil)
    }
}
// swiftlint:enable line_length
