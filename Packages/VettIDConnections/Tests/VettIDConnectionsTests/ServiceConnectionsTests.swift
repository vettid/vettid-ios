import Foundation
import Testing
import VettIDData
import VettIDDataTesting
@testable import VettIDConnections

/// Service connections in the connect flow and the Connections list (VAULT-MESSAGING §6.4 "Service connections", IOS-PLAN
/// §4.13, ANDROID-PLAN §4 "Service connections (0.1.90)"; vettid-android #237's `connectedService`).
@MainActor
@Suite struct ServiceConnectionsTests {
    let fake = FakeConnections()

    static func service(_ id: String, _ first: String, favorite: Bool = false) -> ConnectionInfo {
        var c = Samples.active(id, first: first, last: "Service")
        c.isService = true
        c.favorite = favorite
        return c
    }

    // MARK: - Accepting a service's invitation

    /// The accept's answer said `peer_kind: "service"`: the request says so before the member approves, and the new
    /// connection is a service.
    @Test func acceptingAServicesInvitation() async {
        fake.acceptResult = AcceptedConnection(connectionID: "conn-new", name: "Example Bank", isService: true)
        let m = AcceptViewModel(connections: fake, requests: fake, input: Samples.link())
        await m.settle()
        #expect(m.state.step == .waiting && m.state.service)
        fake.requests = [Samples.outgoing()]
        #expect(await until { m.state.step == .compare && m.state.service })
        m.approve()
        await m.settle()
        fake.connections = [Self.service("conn-new", "Example")]
        #expect(await until { m.state.step == .connected && m.state.connectedService })
    }

    /// The outgoing request's marker alone (the answer had none, e.g. the screen opened on a request the list brought).
    @Test func theRequestsMarkerIsEnough() async {
        let m = AcceptViewModel(connections: fake, requests: fake, input: Samples.link())
        await m.settle()
        #expect(!m.state.service)
        var r = OutgoingRequest(
            connectionID: "conn-new", sas: "042817", remote: false, name: "Inviter", state: .pending, receivedAt: Date(), exp: nil
        )
        r.isService = true
        fake.requests = [.outgoing(r)]
        #expect(await until { m.state.step == .compare && m.state.service })
    }

    @Test func aPersonsInvitationIsAPerson() async {
        let m = AcceptViewModel(connections: fake, requests: fake, input: Samples.link())
        await m.settle()
        fake.requests = [Samples.outgoing()]
        #expect(await until { m.state.step == .compare })
        fake.connections = [Samples.active("conn-new")]
        #expect(await until { m.state.step == .connected })
        #expect(!m.state.service && !m.state.connectedService)
    }

    // MARK: - Being accepted by a service

    /// Only that the flag is passed through, as vettid-android's invite flow does: an accepter declares nothing (§6.4), so
    /// the inviter always sees one as a person and this is not a case a vault produces.
    @Test func aServiceUsingTheInvitationIsConnectedAsAService() async {
        let m = InviteViewModel(connections: fake, requests: fake)
        await m.settle()
        m.create()
        await m.settle()
        fake.requests = [Samples.incoming()]
        await m.settle()
        fake.connections = [Self.service("conn-1", "Example")]
        #expect(await until { m.state.step == .connected && m.state.connectedService })
    }

    // MARK: - The Connections list

    /// The services have their own section below the people, starred first within it; never among the people.
    @Test func servicesAreListedApartFromThePeople() async {
        fake.connections = [
            Self.service("s1", "Beta"), Samples.active("p1", first: "Zoe", last: "Ng"), Self.service("s2", "Zeta", favorite: true),
            Self.service("s3", "Alpha"), Samples.active("p2", first: "Ada", last: "Lovelace"),
        ]
        let m = ConnectionsViewModel(connections: fake, requests: fake)
        await m.settle()
        #expect(m.state.connections.map(\.id) == ["p2", "p1"])
        #expect(m.state.services.map(\.id) == ["s2", "s3", "s1"])
        m.setQuery("zeta")
        #expect(m.state.connections.isEmpty && m.state.services.map(\.id) == ["s2"] && !m.state.noneListed)
        m.setQuery("nobody")
        #expect(m.state.noneListed)
    }

    @Test func withoutAServiceThereIsNoServicesSection() async {
        fake.connections = [Samples.active("p1")]
        let m = ConnectionsViewModel(connections: fake, requests: fake)
        await m.settle()
        #expect(m.state.services.isEmpty && m.state.connections.count == 1)
        // Services alone are not "No connections yet".
        fake.connections = [Self.service("s1", "Example")]
        #expect(await until { m.state.services.count == 1 && m.state.connections.isEmpty && !m.state.isEmpty })
    }

    // MARK: - A service's page

    /// A service shares nothing and is asked for nothing (§6.4): its page never reads `share.rule.list` or `grant.list`,
    /// whether the connection was listed when the page opened or read just after.
    @Test func aServicesPageReadsNoSharing() async {
        let sharing = FakeSharing()
        fake.connections = [Self.service("s1", "Example")]
        let listed = ConnectionDetailViewModel(connectionID: "s1", connections: fake, sharing: sharing)
        await listed.settle()
        listed.loadSharing()
        await listed.settle()
        #expect(sharing.calls.isEmpty && listed.state.connection?.isService == true)
        fake.connections = []
        let read = ConnectionDetailViewModel(connectionID: "s1", connections: fake, sharing: sharing)
        fake.connections = [Self.service("s1", "Example")]
        await read.settle()
        #expect(read.state.connection?.isService == true && sharing.calls.isEmpty)
    }

    /// A person's page reads its sharing, also when the connection was read only after the page opened.
    @Test func aPersonsPageReadsItsSharing() async {
        let sharing = FakeSharing()
        let m = ConnectionDetailViewModel(connectionID: "p1", connections: fake, sharing: sharing)
        fake.connections = [Samples.active("p1")]
        await m.settle()
        #expect(await until { m.state.sharing.loaded })
        #expect(!sharing.calls.isEmpty)
    }
}
