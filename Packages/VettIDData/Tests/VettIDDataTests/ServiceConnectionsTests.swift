import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// Where the app reads that a connection is a service (VAULT-MESSAGING §6.4 "Service connections", §10.4; IOS-PLAN
/// §4.13): `peer_kind: "service"` in `connection.invite.accept`'s answer, `connection.request.outgoing` and the outgoing
/// entries of `connection.request.list`. Only the exact value `"service"` is a service; absent or anything else is a
/// person. An incoming request never carries it.
@Suite struct ServiceConnectionsParserTests {
    let at = Date(timeIntervalSince1970: 1_791_115_200)

    func outgoing(_ extra: String) throws -> OutgoingRequest {
        try #require(ConnectionParser.outgoing(try StrictJson.parseObject(#"{"connection_id":"c1","sas":"654321","state":"pending","name":"Example Bank"\#(extra)}"#), at: at))
    }

    @Test func anOutgoingRequestOfAServiceSaysSo() throws {
        #expect(try outgoing(#","peer_kind":"service""#).isService)
    }

    @Test func anUnknownPeerKindIsAPerson() throws {
        for extra in ["", #","peer_kind":"person""#, #","peer_kind":"Service""#, #","peer_kind":"service ""#, #","peer_kind":7"#, #","peer_kind":null"#, #","peer_kind":["service"]"#] {
            #expect(try !outgoing(extra).isService, "\(extra)")
        }
    }

    /// A later event without the marker keeps it, as it keeps the name and the code.
    @Test func theMarkerIsKeptAcrossAMerge() throws {
        var waiting = OutgoingRequest(connectionID: "c1", sas: nil, remote: false, name: "Example Bank", state: .waiting, receivedAt: at, exp: nil)
        waiting.isService = true
        let newer = try outgoing("")
        guard case .outgoing(let m) = PendingConnection.outgoing(waiting).merged(.outgoing(newer)) else { Issue.record("not outgoing"); return }
        #expect(m.isService && m.sas == "654321")
        guard case .outgoing(let p) = PendingConnection.outgoing(newer).merged(.outgoing(newer)) else { return }
        #expect(!p.isService)
    }
}

/// The same, end to end: this phone against ``FakeVaultService`` accepting a service's invitation, then a person's.
@MainActor
@Suite(.serialized) struct ServiceConnectionsEndToEndTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service)
    }

    var c: ConnectionsManager { phone.manager.connections }

    func setUp() async throws {
        let m = phone.manager
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
    }

    /// The accept's answer, the outgoing event, the request list and the connection all carry the marker.
    @Test func aServicesInvitationIsAServiceThroughout() async throws {
        try await setUp()
        service.holdsHandshakes = true
        let link = try service.peerInvite(first: "Example", last: "Bank", name: "Example Bank", peerKind: "service")
        let r = try await c.acceptInvite(link)
        #expect(r.isService)
        guard case .outgoing(let waiting)? = c.requests.first else { Issue.record("no request"); return }
        #expect(waiting.isService && waiting.state == .waiting)
        try service.runHandshake(r.connectionID)
        #expect(await eventually { c.requests.first?.sas != nil })
        try await c.refreshRequests()
        guard case .outgoing(let listed)? = c.requests.first else { Issue.record("no request"); return }
        #expect(listed.isService && listed.sas != nil)
        try service.peerApproves(r.connectionID)
        try await c.approveOutgoing(r.connectionID)
        #expect(await eventually { c.connections.contains { $0.id == r.connectionID } })
        #expect(c.connections.first { $0.id == r.connectionID }?.isService == true)
    }

    @Test func aPersonsInvitationIsAPerson() async throws {
        try await setUp()
        let r = try await c.acceptInvite(try service.peerInvite())
        #expect(!r.isService)
        #expect(await eventually { c.requests.first?.sas != nil })
        guard case .outgoing(let o)? = c.requests.first else { Issue.record("no request"); return }
        #expect(!o.isService)
    }
}
// swiftlint:enable line_length
