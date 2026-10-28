import Foundation
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDVault

// Event bodies and fixtures stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The vault calls of ``ConnectionsManager``, answered from fixtures; every call recorded.
final class FakeConnectionOps: ConnectionOps, @unchecked Sendable {
    var calls: [String] = []
    var errors: [String: VaultOpError] = [:]
    /// Calls that always fail (`retry`).
    var failing: Set<String> = []
    /// Set: `connection.list` waits for it (a read still under way).
    var listGate: TestDeferred<Void>?
    /// Set: `connection.invite.accept` and `connection.request.list` wait for theirs.
    var acceptGate: TestDeferred<Void>?
    var requestGate: TestDeferred<Void>?
    var limit: UInt64 = 86_400
    var invite = Invite(inviteID: "inv1", link: "", exp: "2026-10-04T12:10:00Z", remote: false)
    var accepted = AcceptedInvite(connectionID: "c-new", state: "waiting", remote: false, exp: "2026-10-12T12:00:00.000Z", name: "Morgan")
    var invites = #"{"invites":[]}"#
    var requests = #"{"incoming":[],"outgoing":[]}"#
    var connections: [String] = []

    private func call(_ name: String) throws {
        calls.append(name)
        if let e = errors.removeValue(forKey: name) { throw e }
        if failing.contains(name) { throw Self.error(name, "retry") }
    }

    static func error(_ type: String, _ code: String, body: String? = nil) -> VaultOpError {
        VaultOpError(type: type, code: code, detail: "", body: body.map { Array($0.utf8) })
    }

    func inviteLifetimeLimit() async throws -> UInt64 { try call("limit"); return limit }
    func inviteCreate(ttlSeconds: Int) async throws -> Invite { try call("inviteCreate:\(ttlSeconds)"); return invite }
    func inviteList() async throws -> JsonObject { try call("inviteList"); return try StrictJson.parseObject(invites) }
    func inviteCancel(_ inviteID: String) async throws { try call("inviteCancel:\(inviteID)") }
    func inviteAccept(_ link: String) async throws -> AcceptedInvite {
        try call("inviteAccept")
        if let g = acceptGate { try await g.value() }
        return accepted
    }
    func connectionApprove(pendingID: String) async throws { try call("approve:\(pendingID)") }
    func connectionDecline(pendingID: String) async throws { try call("decline:\(pendingID)") }
    func outgoingApprove(connectionID: String) async throws { try call("approveOutgoing:\(connectionID)") }
    func outgoingDecline(connectionID: String) async throws { try call("declineOutgoing:\(connectionID)") }
    func requestList() async throws -> JsonObject {
        try call("requestList")
        if let g = requestGate { try await g.value() }
        return try StrictJson.parseObject(requests)
    }
    func connectionList() async throws -> [Connection] {
        try call("list")
        if let g = listGate { try await g.value() }
        return connections.compactMap { (try? StrictJson.parseObject($0)).flatMap(Connection.of) }
    }

    func connectionGet(_ connectionID: String) async throws -> Connection {
        try call("get:\(connectionID)")
        guard let c = try await connectionList().first(where: { $0.id == connectionID }) else { throw Self.error("connection.get", "not_found") }
        calls.removeLast()
        return c
    }

    func connectionUpdate(_ connectionID: String, version: Int64, change: ConnectionMetaChange) async throws -> Int64 {
        try call("update:\(connectionID):\(version)")
        return version + 1
    }

    func connectionRemove(_ connectionID: String) async throws { try call("remove:\(connectionID)") }
    func blockAdd(connectionID: String?, pendingID: String?, note: String?) async throws -> String {
        try call("block:\(connectionID ?? pendingID ?? "")")
        return "b1"
    }

    func connectionAsksMute(_ connectionID: String, muted: Bool) async throws { try call("mute:\(connectionID):\(muted)") }
    func connectionAsksResume(_ connectionID: String) async throws { try call("resume:\(connectionID)") }
}

/// The connections manager over its vault calls: invitations, accepting every form of link, the outgoing request that
/// waits for its handshake, the requests' events and decisions, the owner's metadata and asks. Mirrors the connection
/// parts of vettid-android `SocialManager`'s tests.
@MainActor
@Suite struct ConnectionsManagerTests {
    let ops = FakeConnectionOps()
    let now = Date(timeIntervalSince1970: 1_791_115_200)

    func manager(ops override: FakeConnectionOps? = nil) -> ConnectionsManager {
        let ops = override ?? ops, now = now
        return ConnectionsManager(ops: { ops }, now: { now })
    }

    func event(_ type: String, _ body: String) -> VaultMessage {
        VaultMessage(inner: Inner(id: Ulid.new(), type: type, ts: now, body: Array(body.utf8)))
    }

    func link(_ kind: InviteKind = .connection, exp: TimeInterval = 600) throws -> String {
        try InviteQr(kind: kind, relay: "https://relay.vettid.test", claimID: "abcdefghijklmnopqrstuvwxyz", hash: [UInt8](repeating: 1, count: 32), key: [UInt8](repeating: 2, count: 32), exp: UInt64(now.timeIntervalSince1970 + exp)).link()
    }

    /// The failure kind [op] throws (on the main actor, as the manager runs).
    func kind(_ op: () async throws -> some Any) async -> FailureKind? {
        do {
            _ = try await op()
            return nil
        } catch {
            return (error as? VaultFailure)?.kind
        }
    }

    static func connection(_ id: String, version: Int = 0, favorite: Bool = false) -> String {
        #"{"id":"\#(id)","kind":"connection","state":"active","name":"","ik":"","profile":{"first_name":"Morgan","last_name":"Lee"},"version":\#(version),"favorite":\#(favorite),"archived":false,"asks":{"muted":false,"paused":true,"cooldowns":1}}"#
    }

    /// §6.4: never a lifetime above the relay's limits; 10 minutes at least.
    @Test func theInviteLifetimesFollowTheRelaysLimits() async throws {
        let m = manager()
        #expect(try await m.inviteTtls() == [.tenMinutes, .oneHour, .oneDay])
        #expect(try await m.inviteTtls() == [.tenMinutes, .oneHour, .oneDay])
        #expect(ops.calls == ["limit"], "read once")
        ops.limit = 60
        #expect(try await manager().inviteTtls() == [.tenMinutes])
    }

    @Test func aNewInviteHasItsQrCodeAndUrl() async throws {
        let l = try link()
        ops.invite = Invite(inviteID: "inv1", link: l, exp: "2026-10-04T12:10:00Z", remote: false)
        let i = try await manager().createInvite(.tenMinutes)
        #expect(ops.calls == ["inviteCreate:600"])
        let qr = try InviteLinks.qrPayload(l)
        #expect(i.inviteID == "inv1" && i.link == l && i.qr == qr && i.exp == now.addingTimeInterval(600))
        #expect(i.url == "https://relay.vettid.test/connect#\(l)")
        ops.invites = #"{"invites":[{"invite_id":"a","exp":"2026-10-04T12:10:00Z","remote":false},{"invite_id":"b","exp":"2026-10-04T11:00:00Z","remote":true},{"exp":"x"}]}"#
        #expect(try await manager().outstandingInvites() == [OutstandingInvite(inviteID: "a", exp: now.addingTimeInterval(600), remote: false)])
    }

    /// Every form of §6.4 is accepted and only the bare payload is sent; the outgoing request waits for its code.
    @Test func acceptingALinkMakesAWaitingRequest() async throws {
        let m = manager()
        let r = try await m.acceptInvite("Join me: https://relay.vettid.test/connect#\(try link()) (VettID)")
        #expect(r == AcceptedConnection(connectionID: "c-new", name: "Morgan", exp: FakeDates.date("2026-10-12T12:00:00Z")))
        guard case .outgoing(let o) = try #require(m.requests.first) else { throw VaultFailure(.other) }
        #expect(o.state == .waiting && o.sas == nil && o.name == "Morgan" && m.requests.count == 1)
        // The code arrives (the handshake ran): the request is shown with it.
        m.onEvent(event("connection.request.outgoing", #"{"connection_id":"c-new","sas":"123456","remote":false,"exp":"2026-10-12T12:00:00.000Z"}"#))
        #expect(m.requests.map(\.sas) == ["123456"] && m.requests.first?.state == .pending && m.requests.first?.name == "Morgan")
    }

    /// The outgoing event may overtake the accept's answer: the request keeps its code.
    @Test func anOutgoingEventBeforeTheAnswerIsKept() async throws {
        let m = manager()
        m.onEvent(event("connection.request.outgoing", #"{"connection_id":"c-new","sas":"123456","remote":false}"#))
        _ = try await m.acceptInvite(try link())
        #expect(m.requests.count == 1 && m.requests.first?.sas == "123456")
    }

    @Test func badLinksAreRefusedBeforeAnythingIsSent() async throws {
        let m = manager()
        let k1 = await kind { try await m.acceptInvite("hello") }
        #expect(k1 == .inviteInvalid)
        let k2 = await kind { try await m.acceptInvite(try link(exp: -1)) }
        #expect(k2 == .inviteExpired)
        let k3 = await kind { try await m.acceptInvite(try link(.desktop)) }
        #expect(k3 == .inviteNotConnection)
        #expect(ops.calls.isEmpty)
    }

    /// §6.4 "Already connected": the vault's own id for that peer, and no request.
    @Test func anInviterAlreadyConnectedIsExists() async throws {
        ops.errors["inviteAccept"] = FakeConnectionOps.error("connection.invite.accept", "exists", body: #"{"connection_id":"c7"}"#)
        let m = manager()
        #expect(try await m.acceptInvite(try link()) == AcceptedConnection(connectionID: "c7", exists: true))
        #expect(m.requests.isEmpty)
        ops.errors["inviteAccept"] = FakeConnectionOps.error("connection.invite.accept", "blocked")
        let k4 = await kind { try await m.acceptInvite(try link()) }
        #expect(k4 == .blocked)
        ops.errors["inviteAccept"] = FakeConnectionOps.error("connection.invite.accept", "claim_unavailable")
        let k5 = await kind { try await m.acceptInvite(try link()) }
        #expect(k5 == .inviteUnavailable)
    }

    /// The inviter approves after comparing the code: the request stays, approved, until `added` names it.
    @Test func approvingAnIncomingRequestKeepsItUntilTheConnectionIsAdded() async throws {
        let m = manager()
        m.onEvent(event("connection.request.pending", #"{"pending_id":"p1","invite_id":"i1","sas":"042817","remote":true,"state":"pending","exp":"2026-10-11T12:00:00.000Z","profile":{"first_name":"Alex","last_name":"Kim"}}"#))
        #expect(m.requests.first?.needsDecision == true && m.requests.first?.name == "Alex Kim")
        try await m.approveConnection("p1")
        #expect(ops.calls == ["approve:p1"] && m.requests.first?.state == .approved)
        // A late copy of the event does not take the approval back.
        m.onEvent(event("connection.request.pending", #"{"pending_id":"p1","sas":"042817","state":"pending"}"#))
        #expect(m.requests.first?.state == .approved)
        m.onEvent(event("sync.event", #"{"kind":"connection.request","pending_id":"p1","state":"peer_approved"}"#))
        #expect(m.requests.first?.peerApproved == true)
        ops.connections = [Self.connection("c9")]
        m.onEvent(event("connection.event", #"{"connection_id":"c9","event":"added","pending_id":"p1"}"#))
        #expect(m.requests.isEmpty)
        #expect(await eventually { m.connections.map(\.id) == ["c9"] })
    }

    /// A decision on a request the vault no longer knows ends it here too.
    @Test func decisionsAndTheirEnds() async throws {
        let m = manager()
        for id in ["p1", "p2", "p3"] {
            m.onEvent(event("connection.request.pending", #"{"pending_id":"\#(id)","sas":"042817"}"#))
        }
        m.onEvent(event("connection.request.outgoing", #"{"connection_id":"c1","sas":"111111"}"#))
        try await m.declineConnection("p1")
        try await m.blockConnectionRequest("p2")
        ops.errors["approve:p3"] = FakeConnectionOps.error("connection.approve", "not_found")
        let k6 = await kind { try await m.approveConnection("p3") }
        #expect(k6 == .notFound)
        try await m.approveOutgoing("c1")
        #expect(m.requests.map(\.id) == ["c1"] && m.requests.first?.state == .approved)
        try await m.declineOutgoing("c1")
        #expect(ops.calls == ["decline:p1", "block:p2", "approve:p3", "approveOutgoing:c1", "declineOutgoing:c1"])
        #expect(m.requests.isEmpty)
        #expect(m.requestEnds == ["p1": .declined, "p2": .declined, "p3": .gone, "c1": .declined])
        // A list read sent before the vault said `not_found` does not bring the request back.
        ops.requests = #"{"incoming":[{"pending_id":"p3","sas":"042817","state":"pending"}],"outgoing":[]}"#
        try await m.refreshRequests()
        #expect(m.requests.isEmpty)
    }

    /// The vault's list replaces what events brought; expired requests are not shown; newest first.
    @Test func theRequestListIsAuthoritative() async throws {
        let m = manager()
        m.onEvent(event("connection.request.pending", #"{"pending_id":"gone","sas":"042817"}"#))
        ops.requests = #"{"incoming":[{"pending_id":"p1","invite_id":"i1","sas":"042817","remote":false,"state":"pending","peer_approved":false,"created_at":"2026-10-04T11:00:00.000Z","exp":"2026-10-11T11:00:00.000Z","profile":{"first_name":"Alex","last_name":"Kim"}},{"pending_id":"old","sas":"042817","created_at":"2026-09-01T11:00:00.000Z","exp":"2026-09-08T11:00:00.000Z"}],"outgoing":[{"connection_id":"c1","remote":true,"state":"waiting","peer_approved":false,"created_at":"2026-10-04T11:30:00.000Z","exp":"2026-10-12T11:30:00.000Z","name":"Morgan"}]}"#
        try await m.refreshRequests()
        #expect(m.requests.map(\.key) == ["outgoing:c1", "connection:p1"])
        #expect(m.local.requestNames.keys.sorted() == ["c1", "p1"], "the names the requests showed")
    }

    @Test func aFavoriteIsSetAgainstTheCurrentVersion() async throws {
        ops.connections = [Self.connection("c1", version: 4)]
        let m = manager()
        try await m.refresh()
        ops.connections = [Self.connection("c1", version: 5, favorite: true)]
        try await m.setFavorite("c1", favorite: true)
        #expect(ops.calls == ["list", "update:c1:4", "get:c1"])
        #expect(m.connections.first?.favorite == true && m.connections.first?.version == 5)
        // Another device changed it first: once more against the current version.
        ops.errors["update:c1:5"] = FakeConnectionOps.error("connection.update", "conflict")
        ops.connections = [Self.connection("c1", version: 5, favorite: true)]
        try await m.setFavorite("c1", favorite: false)
        #expect(ops.calls.suffix(4) == ["update:c1:5", "get:c1", "update:c1:5", "get:c1"])
    }

    @Test func asksAreShownAtOnceAndRemoveAndBlockForget() async throws {
        ops.connections = [Self.connection("c1"), Self.connection("c2")]
        let m = manager()
        try await m.refresh()
        let failing = FakeConnectionOps()
        failing.failing = ["list"]
        let quiet = manager(ops: failing)
        quiet.connections = m.connections
        try await quiet.setAsksMuted("c1", muted: true)
        #expect(quiet.connections.first?.asks == AskState(muted: true, paused: true, cooldowns: 1))
        try await quiet.resumeAsks("c1")
        #expect(quiet.connections.first?.asks == AskState(muted: true))
        try await m.remove("c1")
        try await m.block("c2")
        #expect(m.connections.isEmpty && ops.calls.suffix(2) == ["remove:c1", "block:c2"])
    }

    /// Locked or held (IOS-PLAN §6.9: both ``ConnectionsManager/forgetOpenVault()``): what was read from the vault goes,
    /// and what this phone learnt of the requests (their names, the other member's declines) with it. Dropping the
    /// requests alone keeps the connections. A wipe forgets everything.
    @Test func lockingForgetsTheListsAndAWipeEverything() async throws {
        ops.connections = [Self.connection("c1")]
        let m = manager()
        try await m.refresh()
        m.onEvent(event("connection.request.outgoing", #"{"connection_id":"c2","sas":"111111","name":"Sam"}"#))
        m.onEvent(event("sync.event", #"{"kind":"connection.request","connection_id":"c2","state":"peer_declined"}"#))
        m.onEvent(event("connection.request.pending", #"{"pending_id":"p1","sas":"042817"}"#))
        #expect(m.peerDeclines.count == 1 && m.local.requestNames.keys.sorted() == [])
        m.onEvent(event("connection.request.pending", #"{"pending_id":"p2","sas":"042817","profile":{"first_name":"Alex","last_name":"Kim"}}"#))
        #expect(m.local.requestNames.keys.sorted() == ["p2"])
        m.forgetRequests()
        #expect(m.connections.map(\.id) == ["c1"] && m.requests.isEmpty && m.peerDeclines.isEmpty && m.local == .init())
        m.onEvent(event("connection.request.pending", #"{"pending_id":"p3","sas":"042817"}"#))
        m.forgetOpenVault()
        #expect(m.connections.isEmpty && m.requests.isEmpty && m.peerDeclines.isEmpty && m.local == .init())
        // A late `failed` for a decline already told does not tell it again.
        m.onEvent(event("connection.event", #"{"connection_id":"c2","event":"failed","reason":"declined"}"#))
        #expect(m.peerDeclines.isEmpty)
        m.clear()
        #expect(m.peerDeclines.isEmpty && m.requestEnds.isEmpty)
    }

    /// The requests have their own generation: dropping them drops a read of the requests on its way, never a read of the
    /// connections.
    @Test func droppingTheRequestsKeepsAConnectionsReadOnItsWay() async throws {
        ops.connections = [Self.connection("c1")]
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let m = manager()
        let reading = Task { try await m.refresh() }
        #expect(await eventually { ops.calls == ["list"] })
        m.forgetRequests()
        gate.complete(())
        try await reading.value
        #expect(m.connections.map(\.id) == ["c1"])
        ops.requests = #"{"incoming":[{"pending_id":"p1","sas":"042817","state":"pending"}],"outgoing":[]}"#
        let requestGate = TestDeferred<Void>()
        ops.requestGate = requestGate
        let requests = Task { try await m.refreshRequests() }
        #expect(await eventually { ops.calls == ["list", "requestList"] })
        m.forgetRequests()
        requestGate.complete(())
        try await requests.value
        #expect(m.requests.isEmpty && m.connections.map(\.id) == ["c1"])
        ops.requestGate = nil
        try await m.refreshRequests()
        #expect(m.requests.map(\.id) == ["p1"])
    }

    /// A list read before the vault was locked is not published after (chosen; not in the spec).
    @Test func aReadUnderWayWhenTheVaultLocksIsDropped() async throws {
        ops.connections = [Self.connection("c1")]
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let m = manager()
        let reading = Task { try await m.refresh() }
        #expect(await eventually { ops.calls == ["list"] })
        m.forgetOpenVault()
        gate.complete(())
        try await reading.value
        #expect(m.connections.isEmpty)
        ops.listGate = nil
        try await m.refresh()
        #expect(m.connections.map(\.id) == ["c1"])
    }

    /// `connection.event{removed}`: gone at once, then the list is read again.
    @Test func aRemovedConnectionGoesAtOnceThenTheListIsRead() async throws {
        ops.connections = [Self.connection("c1"), Self.connection("c2")]
        let m = manager()
        try await m.refresh()
        ops.failing = ["list"]
        m.onEvent(event("connection.event", #"{"connection_id":"c1","event":"removed"}"#))
        #expect(m.connections.map(\.id) == ["c2"])
        #expect(await eventually { ops.calls.filter { $0 == "list" }.count == 2 })
    }

    /// An accept answered after the vault locked publishes no request (chosen; not in the spec).
    @Test func anAcceptAnsweredAfterALockAddsNothing() async throws {
        let gate = TestDeferred<Void>()
        ops.acceptGate = gate
        let m = manager()
        let l = try link()
        let accepting = Task { try await m.acceptInvite(l) }
        #expect(await eventually { ops.calls == ["inviteAccept"] })
        m.forgetOpenVault()
        gate.complete(())
        #expect(try await accepting.value.connectionID == "c-new")
        #expect(m.requests.isEmpty && m.local.requestNames.isEmpty)
    }

    /// A list read sent before this member's decisions and answered after them takes nothing back (chosen; not in the
    /// spec): the approval stays, the declined request does not come back.
    @Test func aListReadBeforeADecisionTakesNothingBack() async throws {
        let m = manager()
        m.onEvent(event("connection.request.pending", #"{"pending_id":"p1","sas":"042817"}"#))
        m.onEvent(event("connection.request.pending", #"{"pending_id":"p2","sas":"042817"}"#))
        m.onEvent(event("connection.request.outgoing", #"{"connection_id":"c1","sas":"111111","name":"Sam"}"#))
        ops.requests = #"{"incoming":[{"pending_id":"p1","sas":"042817","state":"pending"},{"pending_id":"p2","sas":"042817","state":"pending"}],"outgoing":[{"connection_id":"c1","state":"waiting"}]}"#
        let gate = TestDeferred<Void>()
        ops.requestGate = gate
        let reading = Task { try await m.refreshRequests() }
        #expect(await eventually { ops.calls == ["requestList"] })
        ops.requestGate = nil
        try await m.approveConnection("p1")
        try await m.declineConnection("p2")
        gate.complete(())
        try await reading.value
        #expect(m.requests.map(\.id).sorted() == ["c1", "p1"])
        #expect(m.requests.first { $0.id == "p1" }?.state == .approved)
        #expect(m.requests.first { $0.id == "c1" }?.sas == "111111" && m.requests.first { $0.id == "c1" }?.name == "Sam")
    }

    /// The reads nobody asked for go over the quiet calls only: when the session is gone between the two reads of an
    /// opening (the app went to the background), the second is not sent and nothing opens a session.
    @Test func backgroundReadsNeverUseTheCallsThatOpenASession() async throws {
        let ops = ops, now = now
        var quietCalls = 0
        let m = ConnectionsManager(
            ops: {
                Issue.record("a background read used the calls that open a session")
                return ops
            },
            quietOps: {
                quietCalls += 1
                if quietCalls > 1 { throw VaultFailure(.other, code: "session_dropped") }
                return ops
            },
            now: { now }
        )
        m.refreshAllQuietly()
        #expect(await eventually { quietCalls == 2 })
        #expect(ops.calls == ["list"])
        m.onEvent(event("sync.event", #"{"kind":"connection.changed","connection_id":"c1","version":1}"#))
        #expect(await eventually { quietCalls == 3 })
    }

    /// A connection the vault no longer lists (removed on another device) is forgotten with its conversation; one that
    /// stays, or a new one, is not.
    @Test func aConnectionGoneFromTheListTakesItsConversation() async throws {
        ops.connections = [Self.connection("c1"), Self.connection("c2")]
        let m = manager()
        var forgotten: [String] = []
        m.onForget = { forgotten.append($0) }
        try await m.refresh()
        #expect(forgotten.isEmpty)
        ops.connections = [Self.connection("c2"), Self.connection("c3")]
        try await m.refresh()
        #expect(forgotten == ["c1"] && m.connections.map(\.id) == ["c2", "c3"])
    }

    /// A connection read while an older list was on its way is neither dropped nor forgotten by that list.
    @Test func aConnectionReadDuringAListReadStays() async throws {
        ops.connections = [Self.connection("c1")]
        let m = manager()
        var forgotten: [String] = []
        m.onForget = { forgotten.append($0) }
        try await m.refresh()
        ops.connections = []
        let gate = TestDeferred<Void>()
        ops.listGate = gate
        let list = Task { try await m.refresh() }
        #expect(await eventually { ops.calls.filter { $0 == "list" }.count == 2 })
        ops.listGate = nil
        ops.connections = [Self.connection("c2")]
        _ = try await m.connection("c2")
        ops.connections = []
        gate.complete(())
        try await list.value
        #expect(m.connections.map(\.id) == ["c2"] && forgotten == ["c1"])
    }
}

// swiftlint:enable line_length
