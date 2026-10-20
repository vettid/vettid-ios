import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDConnections

/// The Connections list (ANDROID-PLAN §4; VAULT-MESSAGING §6.4, §10.4): loading, empty and failed reads, favourites
/// first then by name, the search, the invitations and their cancelling, the other member's declines, and the open
/// requests decided here, including one that ended meanwhile. Mirrors vettid-android `ConnectionsViewModelsTest`'s list
/// part.
@MainActor
@Suite struct ConnectionsViewModelTests {
    let fake = FakeConnections()

    func model() async -> ConnectionsViewModel {
        let m = ConnectionsViewModel(connections: fake, requests: fake)
        await m.settle()
        return m
    }

    static func connection(_ id: String, _ first: String?, _ last: String?, favorite: Bool = false, name: String = "") -> ConnectionInfo {
        var c = Samples.active(id, first: first, last: last)
        c.favorite = favorite
        c.name = name
        return c
    }

    @Test func itLoadsTheConnectionsTheInvitationsAndTheRequests() async {
        let m = ConnectionsViewModel(connections: fake, requests: fake)
        #expect(m.state.loading && m.state.connections.isEmpty)
        await m.settle()
        #expect(!m.state.loading && m.state.error == nil && m.state.isEmpty && !m.state.searchable)
        #expect(fake.calls == ["refresh", "outstandingInvites", "refreshRequests"])
    }

    @Test func aFailedReadSaysWhyAndRetries() async {
        fake.fail["refresh"] = VaultFailure(.network)
        let m = await model()
        #expect(!m.state.loading && m.state.error == .network && m.state.isEmpty)
        m.refresh()
        #expect(m.state.error == nil)
        await m.settle()
        #expect(m.state.error == nil && fake.calls.filter { $0 == "refresh" }.count == 2)
        // A failure over a list already shown is dismissed with OK.
        fake.connections = [Self.connection("c1", "Ada", "Lovelace")]
        fake.fail["outstandingInvites"] = VaultFailure(.network)
        m.refresh()
        await m.settle()
        #expect(m.state.error == .network && m.state.connections.count == 1 && !m.state.isEmpty)
        m.dismissError()
        #expect(m.state.error == nil)
    }

    /// Favourites first, then by the title, lower-cased; "Name not shared yet" ("") first among its group (as
    /// vettid-android's sort).
    @Test func favouritesComeFirstThenByName() async {
        fake.connections = [
            Self.connection("c1", "zoe", "Zed"), Self.connection("c2", "Ada", "Lovelace"),
            Self.connection("c3", "Grace", "Hopper", favorite: true), Self.connection("c4", nil, nil),
            Self.connection("c5", "Alan", "Turing", favorite: true),
        ]
        let m = await model()
        #expect(m.state.connections.map(\.id) == ["c5", "c3", "c4", "c2", "c1"] && m.state.searchable)
        m.setFavorite("c1", true)
        await m.settle()
        #expect(fake.calls.last == "setFavorite")
        #expect(m.state.connections.map(\.id) == ["c5", "c3", "c1", "c4", "c2"])
        fake.fail["setFavorite"] = VaultFailure(.conflict)
        m.setFavorite("c2", true)
        await m.settle()
        #expect(m.state.error == .conflict && !m.state.connections.first { $0.id == "c2" }!.favorite)
    }

    /// The search matches the title or the display name, ignoring case; while searching only the connections show.
    @Test func theSearchFiltersByName() async {
        fake.connections = [Self.connection("c1", "Ada", "Lovelace"), Self.connection("c2", "Grace", "Hopper", name: "Amazing Grace")]
        fake.outstanding = [OutstandingInvite(inviteID: "i1", exp: nil, remote: false)]
        fake.requests = [Samples.incoming()]
        let m = await model()
        m.setQuery("  lovelace ")
        #expect(m.state.searching && m.state.connections.map(\.id) == ["c1"])
        m.setQuery("amazing")
        #expect(m.state.connections.map(\.id) == ["c2"])
        m.setQuery("nobody")
        #expect(m.state.connections.isEmpty && m.state.searchable)
        m.setQuery("")
        #expect(!m.state.searching && m.state.connections.count == 2)
    }

    @Test func anInvitationIsCancelledOnceConfirmed() async {
        let invite = OutstandingInvite(inviteID: "i1", exp: Date().addingTimeInterval(600), remote: true)
        fake.outstanding = [invite]
        let m = await model()
        #expect(m.state.invites == [invite] && !m.state.isEmpty)
        m.askCancel(invite)
        #expect(m.state.cancelling == invite)
        m.askCancel(nil)
        m.confirmCancel()
        await m.settle()
        #expect(!fake.calls.contains("cancelInvite") && m.state.invites == [invite])
        m.askCancel(invite)
        m.confirmCancel()
        await m.settle()
        #expect(fake.calls.contains("cancelInvite") && m.state.invites.isEmpty && m.state.cancelling == nil)
    }

    @Test func aPeersDeclineShowsUntilDismissed() async {
        fake.peerDeclines = [PeerDecline(requestID: "r1", name: "Ada Lovelace", outgoing: true, at: Date())]
        let m = await model()
        #expect(m.state.peerDeclines.count == 1 && !m.state.isEmpty)
        m.dismissPeerDecline("r1")
        #expect(m.state.peerDeclines.isEmpty && fake.calls.contains("dismissPeerDecline"))
    }

    /// Incoming requests go to the inviter's calls, outgoing ones to the accepter's.
    @Test func requestsAreApprovedAndDeclinedOnTheirSide() async {
        fake.requests = [Samples.incoming("p1"), Samples.outgoing("o1")]
        let m = await model()
        #expect(m.state.requests.map(\.id) == ["p1", "o1"])
        m.approve(m.state.requests[0])
        #expect(m.state.deciding == ["p1"])
        await m.settle()
        #expect(m.state.deciding.isEmpty && m.state.requests[0].state == .approved)
        m.approve(m.state.requests[1])
        await m.settle()
        #expect(fake.calls.suffix(2) == ["approveConnection", "approveOutgoing"])
        m.decline(m.state.requests[1])
        m.decline(m.state.requests[0])
        await m.settle()
        #expect(fake.calls.suffix(2) == ["declineOutgoing", "declineConnection"] && m.state.requests.isEmpty)
        #expect(m.state.ended == nil && m.state.error == nil)
    }

    /// A decision on a request the vault no longer has (decided on another device, or expired): told as "already
    /// decided", not as a failure; another failure keeps the request and says why.
    @Test func aRequestThatEndedMeanwhileIsToldSo() async {
        fake.goneOnNotFound = true
        fake.requests = [Samples.incoming("p1"), Samples.outgoing("o1")]
        let m = await model()
        fake.fail["approveConnection"] = VaultFailure(.notFound)
        m.approve(m.state.requests[0])
        await m.settle()
        #expect(m.state.ended == EndedRequest(requestID: "p1", end: .gone) && m.state.error == nil)
        #expect(m.state.requests.map(\.id) == ["o1"])
        m.dismissEnded()
        #expect(m.state.ended == nil)
        fake.fail["declineOutgoing"] = VaultFailure(.network)
        m.decline(m.state.requests[0])
        await m.settle()
        #expect(m.state.error == .network && m.state.ended == nil && m.state.requests.map(\.id) == ["o1"])
    }

    /// The other member declined while this member was deciding (0.10.5): their decline notice tells it, no second
    /// notice and no failure.
    @Test func aPeersDeclineRacingADecisionIsToldOnce() async {
        fake.requests = [Samples.outgoing("o1")]
        let m = await model()
        fake.requestEnds["o1"] = .peerDeclined
        fake.peerDeclines = [PeerDecline(requestID: "o1", name: "Inviter", outgoing: true, at: Date())]
        fake.fail["approveOutgoing"] = VaultFailure(.notFound)
        m.approve(m.state.requests[0])
        await m.settle()
        #expect(m.state.ended == nil && m.state.error == nil && m.state.peerDeclines.count == 1)
    }

    /// A list refused because the daily check was due reads again by itself once a check passes (vettid-android
    /// `checkCleared`); a passed check leaves another failure alone.
    @Test func aPassedCheckReadsARefusedListAgain() async {
        let vault = FakeVaultRepository(.unlocked)
        vault.ownerCheck = OwnerCheckView(state: .due, deadline: nil, hold: false)
        fake.fail["refresh"] = VaultFailure(.ownerCheckRequired)
        let m = ConnectionsViewModel(connections: fake, requests: fake, ownerChecks: vault, account: vault)
        await m.settle()
        #expect(m.state.error == .ownerCheckRequired && m.state.invites.isEmpty)
        let invite = OutstandingInvite(inviteID: "i1", exp: nil, remote: false)
        fake.outstanding = [invite]
        vault.ownerCheck = OwnerCheckView(state: .ok, deadline: Date(), hold: false)
        await m.settle()
        #expect(m.state.error == nil && m.state.invites == [invite])
        fake.fail["refresh"] = VaultFailure(.network)
        m.refresh()
        await m.settle()
        let reads = fake.calls.filter { $0 == "refresh" }.count
        vault.ownerCheck = OwnerCheckView(state: .ok, deadline: Date().addingTimeInterval(60), hold: false)
        await m.settle()
        #expect(m.state.error == .network && fake.calls.filter { $0 == "refresh" }.count == reads)
    }

    /// Locked: the invitations read from the open vault go; an unlock reads them again.
    @Test func aLockDropsTheInvitations() async {
        let vault = FakeVaultRepository(.unlocked)
        let invite = OutstandingInvite(inviteID: "i1", exp: nil, remote: false)
        fake.outstanding = [invite]
        let m = ConnectionsViewModel(connections: fake, requests: fake, ownerChecks: vault, account: vault)
        await m.settle()
        m.askCancel(invite)
        #expect(m.state.invites == [invite])
        vault.phase = .locked
        await m.settle()
        #expect(m.state.invites.isEmpty && m.state.cancelling == nil)
        vault.phase = .unlocked
        await m.settle()
        #expect(m.state.invites == [invite] && fake.calls.filter { $0 == "outstandingInvites" }.count == 2)
    }

    /// The state never prints the names it holds.
    @Test func theStateDoesNotPrintNames() async {
        fake.connections = [Self.connection("c1", "Ada", "Lovelace")]
        let m = await model()
        #expect(!"\(m.state)".contains("Ada") && !String(reflecting: m.state).contains("Ada"))
    }
}
