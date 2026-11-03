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

    // 32 bytes 0x00...0x1f: the vector-free shape check; the fingerprint is IkFingerprint's (which has the vectors).
    static let ikBytes = [UInt8](0..<32)
    static let ikStd = Data(ikBytes).base64EncodedString()
    static let ikURL = ikStd.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")

    /// `ik` of `connection.request.outgoing` (0.83.7 §10.4) decodes to its 32 bytes and the fingerprint of the crypto package.
    @Test func theOutgoingEventCarriesIk() throws {
        let r = try outgoing(#","peer_kind":"service","ik":"\#(Self.ikStd)""#)
        #expect(r.ik == Self.ikBytes)
        #expect(r.keyFingerprint == (try IkFingerprint.format(Self.ikBytes)))
    }

    /// The same from an outgoing entry of `connection.request.list`.
    @Test func theListEntryCarriesIk() throws {
        let o = try StrictJson.parseObject(#"{"connection_id":"c1","sas":"654321","ik":"\#(Self.ikStd)","state":"pending","remote":false,"peer_approved":false,"created_at":"2026-11-03T10:00:00Z","exp":"2026-11-10T10:00:00Z","peer_kind":"service"}"#)
        #expect(try #require(ConnectionParser.outgoing(o, at: at)).ik == Self.ikBytes)
    }

    @Test func noIkFromAnOlderVault() throws {
        let r = try outgoing(#","peer_kind":"service""#)
        #expect(r.ik == nil && r.keyFingerprint == nil)
    }

    /// A malformed `ik` does not break the request: it is shown without one.
    @Test func aMalformedIkIsDroppedAndTheRequestKept() throws {
        let short = Data([UInt8](0..<31)).base64EncodedString()
        // Non-canonical: non-zero padding bits (the last character changed to one with the same high bits), a line break,
        // base64url (unpadded and padded).
        var chars = Array(Self.ikStd)
        chars[chars.count - 2] = "9"
        let padBits = String(chars)
        // A key whose standard form has "+" and "/", so that its URL-safe form really differs.
        let std = Base64s.encodeStd([UInt8](repeating: 0xFB, count: 32))
        let padded = std.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(padded != std && padded.hasSuffix("="))
        #expect(padBits != Self.ikStd && Data(base64Encoded: padBits) != nil)
        for bad in [#""ik":"\#(padBits)""#, #""ik":"\#(Self.ikStd.prefix(20))\n\#(Self.ikStd.dropFirst(20))""#, #""ik":"\#(Self.ikURL)""#, #""ik":"\#(padded)""#, #""ik":"""#, #""ik":"!!!""#, #""ik":"\#(short)""#, #""ik":7"#, #""ik":null"#, #""ik":"\#(Self.ikStd)00""#] {
            let r = try outgoing(#","peer_kind":"service",\#(bad)"#)
            #expect(r.ik == nil && r.sas == "654321" && r.isService, "\(bad)")
        }
    }

    /// `ik` comes with `sas`: an entry without a code (`waiting`) shows none.
    @Test func ikWithoutASasIsIgnored() throws {
        let o = try StrictJson.parseObject(#"{"connection_id":"c1","state":"waiting","ik":"\#(Self.ikStd)"}"#)
        let r = try #require(ConnectionParser.outgoing(o, at: at))
        #expect(r.ik == nil && r.state == .waiting)
    }

    /// The waiting entry has no `ik`; the event that follows brings it, and a later one without it keeps it.
    @Test func ikIsKeptAcrossAMerge() throws {
        let waiting = OutgoingRequest(connectionID: "c1", sas: nil, remote: false, name: "Example Bank", state: .waiting, receivedAt: at, exp: nil)
        let withIk = try outgoing(#","ik":"\#(Self.ikStd)""#)
        let noIk = try outgoing("")
        guard case .outgoing(let a) = PendingConnection.outgoing(waiting).merged(.outgoing(withIk)),
              case .outgoing(let b) = PendingConnection.outgoing(withIk).merged(.outgoing(noIk)) else { Issue.record("not outgoing"); return }
        #expect(a.ik == Self.ikBytes && b.ik == Self.ikBytes)
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
