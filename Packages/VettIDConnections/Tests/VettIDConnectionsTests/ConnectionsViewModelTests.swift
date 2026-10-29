import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDConnections

/// The Connections list (ANDROID-PLAN §4; VAULT-MESSAGING §6.4, §10.4): loading, empty and failed reads, favourites
/// first then by name, the search, the invitations and their cancelling, and the other member's declines (the requests
/// are decided in Approvals). Mirrors vettid-android `ConnectionsViewModelsTest`'s list part.
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
        #expect(fake.calls == ["refresh", "outstandingInvites"])
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

    /// The search and the order read the cleaned names: a hidden control character neither hides a match nor makes one
    /// (VAULT-MESSAGING §10.8; mirrors vettid-android #220).
    @Test func theSearchAndTheOrderReadCleanedNames() async {
        fake.connections = [
            Self.connection("c1", "Ada", "Love\u{200B}lace"), Self.connection("c2", "\u{202E}Abe", "Zed", name: "Ada\u{2069}"),
        ]
        let m = await model()
        m.setQuery("lovelace")
        #expect(m.state.connections.map(\.id) == ["c1"])
        m.setQuery("")
        #expect(m.state.connections.map(\.id) == ["c2", "c1"])
        #expect(AccountNames.cleaned("Bank\u{2069}\u{202E}") == "Bank")
        // The secondary name is compared and returned cleaned.
        #expect(Self.connection("c3", "Ada", "Lovelace", name: "Ada\u{202E} Lovelace").secondaryName == nil)
        #expect(Self.connection("c3", "Ada", "Lovelace", name: "\u{2069}Countess\u{202E}").secondaryName == "Countess")
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
        // The view model follows the check on a later turn of the main actor (``until``).
        #expect(await until { m.state.error == nil && m.state.invites == [invite] })
        await m.settle()
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
