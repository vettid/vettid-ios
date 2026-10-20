import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDVault

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The vault's connection bodies as the app reads them (VAULT-MESSAGING §10.4, §10.4.1, §10.8): connections with their
/// peer's profile, both kinds of request with their safety codes, and the strict core of a shared profile. Mirrors the
/// connection parts of vettid-android `ApprovalParserTest` and `PeerProfile`'s rules.
@Suite struct ConnectionParserTests {
    let at = Date(timeIntervalSince1970: 1_791_115_200)
    static let ik = [UInt8](repeating: 7, count: 32)
    static var ikB64: String { Base64s.encodeStd(ik) }

    func object(_ s: String) throws -> JsonObject { try StrictJson.parseObject(s) }

    @Test func aConnectionWithItsPeersProfile() throws {
        let o = try object(#"{"id":"c1","kind":"connection","state":"active","name":"Old","ik":"\#(Self.ikB64)","profile":{"version":3,"first_name":"Morgan","last_name":"Lee","ik":"\#(Self.ikB64)","name":"Mo","photo":"AAAA","items":[{"item_id":"i1","name":"Phone","fields":[{"label":"Mobile","value":"+1 555"},{"label":"Home","value":{"street":"1 Main St","city":"Springfield","zip":" "}},{"label":"Bad","value":7}]}]},"created_at":"2026-10-01T10:00:00.000Z","last_active_at":"2026-10-04T11:59:00.000Z","version":2,"alias":"a","note":"n","tags":["family","x"],"favorite":true,"archived":false,"asks":{"muted":true,"paused":true,"paused_at":"2026-10-03T00:00:00.000Z","cooldowns":2},"future":1}"#)
        let c = try #require(Connection.of(o))
        let i = ConnectionParser.connection(c)
        #expect(i.id == "c1" && i.state == .active && i.favorite && !i.archived && i.version == 2 && i.tags == ["family", "x"])
        #expect(i.displayName == "Morgan Lee" && i.accountName == "Morgan Lee")
        #expect(i.name == "Mo" && i.secondaryName == "Mo", "the profile's display name wins over the connection's")
        #expect(i.hasPhoto && i.photo == "AAAA")
        let fingerprint = try IkFingerprint.format(Self.ik)
        #expect(i.keyFingerprint == fingerprint)
        #expect(i.createdAt == FakeDates.date("2026-10-01T10:00:00Z") && i.lastActiveAt == FakeDates.date("2026-10-04T11:59:00Z"))
        #expect(i.asks == AskState(muted: true, paused: true, pausedAt: FakeDates.date("2026-10-03T00:00:00Z"), cooldowns: 2))
        #expect(i.sharedItems == [SharedProfileItem(itemID: "i1", name: "Phone", fields: [.init("Mobile", "+1 555"), .init("Home", "1 Main St, Springfield")])])
    }

    @Test func beforeTheFirstProfileTheTitleIsEmptyAndTheNameIsSecondary() throws {
        let c = try #require(Connection.of(try object(#"{"id":"c2","state":"stale","name":"Sam","ik":"bad"}"#)))
        let i = ConnectionParser.connection(c)
        #expect(i.state == .stale && i.displayName == "" && i.secondaryName == "Sam" && i.keyFingerprint == nil && i.asks == nil)
        #expect(Connection.of(try object(#"{"state":"active"}"#)) == nil)
        #expect(ConnectionState.of("blocked") == .blocked && ConnectionState.of("new-state") == .other)
    }

    /// §10.8: a core that breaks the rules yields no names at all, never a partial one; the extras stay.
    @Test func theProfilesCoreIsStrict() throws {
        let long = String(repeating: "é", count: 81) // 162 bytes
        for bad in [#"{"first_name":"Morgan"}"#, #"{"first_name":"","last_name":"Lee"}"#, #"{"first_name":"Mor\u0007gan","last_name":"Lee"}"#,
                    #"{"first_name":"\#(long)","last_name":"Lee"}"#, #"{"first_name":"Morgan","last_name":"Lee","ik":"AAAA"}"#,
                    #"{"first_name":"Morgan","last_name":"Lee","ik":7}"#, #"{"first_name":"Morgan","last_name":"Lee","ik":"\#(Self.ikB64)","name":"Mo"}"#.replacingOccurrences(of: "Lee", with: "Lee\u{2028}")] {
            let p = try #require(PeerProfile.parse(try object(bad)))
            #expect(p.firstName == nil && p.lastName == nil && p.accountName == nil, "\(bad)")
        }
        let ok = try #require(PeerProfile.parse(try object(#"{"first_name":"Morgan","last_name":"Lee","name":"   "}"#)))
        #expect(ok.accountName == "Morgan Lee" && ok.displayName == nil && !ok.hasPhoto && ok.items.isEmpty)
        #expect(PeerProfile.parse(nil) == nil)
        let tooLong = String(repeating: "a", count: 129)
        #expect(PeerProfile.displayName(try object(#"{"name":"\#(tooLong)"}"#)) == nil)
        let bigPhoto = String(repeating: "A", count: PeerProfile.maxPhotoChars + 1)
        let p = try #require(PeerProfile.parse(try object(#"{"first_name":"Morgan","last_name":"Lee","photo":"\#(bigPhoto)"}"#)))
        #expect(p.hasPhoto && p.photo == nil, "a photo above the limit is not kept")
    }

    @Test func anIncomingRequest() throws {
        let r = try #require(ConnectionParser.incoming(try object(#"{"pending_id":"p1","invite_id":"i1","sas":"042817","remote":true,"state":"approved","peer_approved":true,"created_at":"2026-10-04T11:00:00.000Z","exp":"2026-10-11T11:00:00.000Z","profile":{"first_name":"Alex","last_name":"Kim","name":"Al"},"introduced_by":"c9"}"#), at: at))
        #expect(r.pendingID == "p1" && r.inviteID == "i1" && r.sas == "042817" && r.remote && r.state == .approved && r.peerApproved)
        #expect(r.name == "Alex Kim" && r.displayName == "Al" && r.introducedBy == "c9")
        #expect(r.receivedAt == FakeDates.date("2026-10-04T11:00:00Z") && r.exp == FakeDates.date("2026-10-11T11:00:00Z"))
        // The event: received now, kept 7 days; a display name equal to the account's name is not repeated.
        let e = try #require(ConnectionParser.incoming(try object(#"{"pending_id":"p2","sas":"123456","profile":{"first_name":"Alex","last_name":"Kim","name":"Alex Kim"}}"#), at: at))
        #expect(e.receivedAt == at && e.exp == at.addingTimeInterval(7 * 86_400) && e.state == .pending && e.displayName == nil && !e.remote)
        // Without a well-formed code there is nothing to compare: not shown.
        for sas in ["12345", "1234567", "12a456", "１２３４５６"] {
            #expect(ConnectionParser.incoming(try object(#"{"pending_id":"p3","sas":"\#(sas)"}"#), at: at) == nil)
        }
        #expect(ConnectionParser.incoming(try object(#"{"sas":"123456"}"#), at: at) == nil)
    }

    /// An outgoing request without its code is `waiting`, whatever its state says; with it, never `waiting` (0.10.3).
    @Test func anOutgoingRequest() throws {
        let w = try #require(ConnectionParser.outgoing(try object(#"{"connection_id":"c1","state":"pending","remote":false,"name":"  ","exp":"2026-10-12T12:00:00.000Z"}"#), at: at))
        #expect(w.state == .waiting && w.sas == nil && w.name == nil && w.exp == FakeDates.date("2026-10-12T12:00:00Z"))
        let p = try #require(ConnectionParser.outgoing(try object(#"{"connection_id":"c1","sas":"654321","state":"waiting","name":"Morgan","peer_approved":true}"#), at: at))
        #expect(p.state == .pending && p.sas == "654321" && p.name == "Morgan" && p.peerApproved && p.receivedAt == at)
        let a = try #require(ConnectionParser.outgoing(try object(#"{"connection_id":"c1","sas":"654321","state":"approved"}"#), at: at))
        #expect(a.state == .approved && PendingConnection.outgoing(a).key == "outgoing:c1" && !PendingConnection.outgoing(a).needsDecision)
    }

    /// An event never takes back what a decision already moved on; the peer's approval stays; an outgoing request keeps
    /// its name.
    @Test func aNewerRequestMergesOverAnOlderOne() {
        var old = OutgoingRequest(connectionID: "c1", sas: "111111", remote: false, name: "Morgan", state: .approved, receivedAt: at, exp: nil)
        old.peerApproved = true
        let newer = OutgoingRequest(connectionID: "c1", sas: "111111", remote: false, name: nil, state: .pending, receivedAt: at, exp: nil)
        let m = PendingConnection.outgoing(old).merged(.outgoing(newer))
        #expect(m.state == .approved && m.peerApproved && m.name == "Morgan")
        let waiting = OutgoingRequest(connectionID: "c1", sas: nil, remote: false, name: "Morgan", state: .waiting, receivedAt: at, exp: nil)
        #expect(PendingConnection.outgoing(waiting).merged(.outgoing(newer)).state == .pending)
        #expect(PendingConnection.outgoing(waiting).needsDecision == false && PendingConnection.outgoing(newer).needsDecision)
    }

    @Test func askStates() {
        let a = AskState(muted: true, paused: true, pausedAt: at, cooldowns: 3)
        #expect(a.canResume && !AskState(muted: true).canResume && AskState(cooldowns: 1).canResume)
        #expect(a.muted(false) == AskState(muted: false, paused: true, pausedAt: at, cooldowns: 3), "unmuting does not resume a pause")
        #expect(a.resumed() == AskState(muted: true), "a resume ends the pause and the cooldowns; the mute stays")
    }
}

// swiftlint:enable line_length
