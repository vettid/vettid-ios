import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDVault

// Event bodies stay on one line each.
// swiftlint:disable line_length

/// VAULT-MESSAGING 0.10.5 (§6.4, §10.1): the other member's decline (`sync.event{connection.request, state:
/// "peer_declined"}`, and on the accepter's side `connection.event{failed, reason: "declined"}`) ends the request and is
/// told once, with the name the request showed. The member's own decline is unchanged. Mirrors vettid-android
/// `PeerDeclineTest`.
@MainActor
@Suite struct PeerDeclineTests {
    let now = Date(timeIntervalSince1970: 1_791_201_600)

    /// No vault: the list refreshes fail quietly.
    func manager() -> ConnectionsManager {
        let ops = FakeConnectionOps()
        ops.failing = ["list"]
        let now = now
        return ConnectionsManager(ops: { ops }, now: { now })
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    func outgoing(_ m: ConnectionsManager, _ id: String, _ name: String) {
        m.onEvent(event("connection.request.outgoing", #"{"connection_id":"\#(id)","sas":"123456","name":"\#(name)","state":"approved","remote":false}"#))
    }

    func incoming(_ m: ConnectionsManager, _ id: String, _ first: String, _ last: String) {
        m.onEvent(event("connection.request.pending", #"{"pending_id":"\#(id)","invite_id":"i1","sas":"042817","profile":{"first_name":"\#(first)","last_name":"\#(last)"},"remote":true}"#))
    }

    func failed(_ m: ConnectionsManager, _ id: String, _ reason: String?) {
        m.onEvent(event("connection.event", #"{"connection_id":"\#(id)","event":"failed"\#(reason.map { #","reason":"\#($0)""# } ?? "")}"#))
    }

    func sync(_ m: ConnectionsManager, _ key: String, _ id: String, _ state: String) {
        m.onEvent(event("sync.event", #"{"kind":"connection.request","\#(key)":"\#(id)","state":"\#(state)"}"#))
    }

    @Test func theAccepterIsToldOnceWhicheverEventComesFirst() {
        let m = manager()
        outgoing(m, "c1", "Morgan Lee")
        outgoing(m, "c2", "Sam")
        #expect(m.requests.count == 2)
        // failed{reason: declined} first, then the sync.event.
        failed(m, "c1", "declined")
        sync(m, "connection_id", "c1", "peer_declined")
        // The sync.event first, then failed.
        sync(m, "connection_id", "c2", "peer_declined")
        failed(m, "c2", "declined")
        #expect(m.requests.isEmpty)
        #expect(m.peerDeclines == [
            PeerDecline(requestID: "c1", name: "Morgan Lee", outgoing: true, at: now), PeerDecline(requestID: "c2", name: "Sam", outgoing: true, at: now),
        ])
        #expect(m.requestEnds["c1"] == .peerDeclined && m.requestEnds["c2"] == .peerDeclined)
    }

    @Test func theInviterIsToldWithTheRequestsNameUntilDismissedInMemoryOnly() {
        let m = manager()
        incoming(m, "p1", "Alex", "Kim")
        sync(m, "pending_id", "p1", "peer_declined")
        #expect(m.requests.isEmpty)
        #expect(m.peerDeclines == [PeerDecline(requestID: "p1", name: "Alex Kim", outgoing: false, at: now)])
        // Kept in memory until the member dismisses it; a new start has none.
        #expect(manager().peerDeclines.isEmpty)
        m.dismissPeerDecline("p1")
        #expect(m.peerDeclines.isEmpty)
    }

    @Test func theNameIsKeptAfterTheRequestLeftTheList() {
        let m = manager()
        outgoing(m, "c3", "Jordan")
        // A bare failed (an older ordering) ends the request; the peer's decline that follows still names it.
        failed(m, "c3", nil)
        #expect(m.requestEnds["c3"] == .failed && m.peerDeclines.isEmpty)
        sync(m, "connection_id", "c3", "peer_declined")
        #expect(m.peerDeclines.map(\.name) == ["Jordan"] && m.requestEnds["c3"] == .peerDeclined)
        // And a request this app never saw is told without a name.
        sync(m, "pending_id", "p9", "peer_declined")
        #expect(m.peerDeclines.last?.name == nil && m.peerDeclines.last?.outgoing == false)
    }

    @Test func theMembersOwnDeclineAndOtherEndsAreUnchanged() {
        let m = manager()
        outgoing(m, "c4", "Morgan")
        incoming(m, "p4", "Alex", "Kim")
        outgoing(m, "c5", "Sam")
        // Declined on another of this member's devices (0.10.4), an expiry and a failure: no peer decline.
        sync(m, "pending_id", "p4", "declined")
        sync(m, "connection_id", "c4", "expired")
        failed(m, "c5", nil)
        #expect(m.requests.isEmpty && m.peerDeclines.isEmpty)
        #expect(m.requestEnds == ["p4": .declined, "c4": .expired, "c5": .failed])
    }
}

// swiftlint:enable line_length
