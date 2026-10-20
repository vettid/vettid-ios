import Foundation
import Observation
import VettIDData

/// TEST ONLY. In-memory connections, invitations and connection requests for view-model tests, like
/// ``FakeVaultRepository``: every call is recorded in ``calls``; ``fail`` makes the next call of a name throw. Observable,
/// as ``ConnectionsManager`` is. Mirrors the connection part of vettid-android `FakeSocial`.
@MainActor
@Observable
public final class FakeConnections: ConnectionsRepository, ConnectionRequestsRepository {
    /// Every call, by name, in order.
    public var calls: [String] = []
    /// A failure the next call of that name throws (once).
    public var fail: [String: VaultFailure] = [:]
    public var lastText: String?
    public var acceptResult = AcceptedConnection(connectionID: "conn-new", name: "Inviter")
    public var ttls = InviteTtl.allCases
    public var invite = InviteInfo(
        inviteID: "01JINVITE0000000000000000A", link: "link", qr: "{}", exp: Date(timeIntervalSince1970: 1_791_115_800), remote: false
    )
    public var outstanding: [OutstandingInvite] = []

    public var connections: [ConnectionInfo] = []
    public var requests: [PendingConnection] = []
    public var requestEnds: [String: RequestEnd] = [:]
    public var peerDeclines: [PeerDecline] = []
    /// A decision that fails with `notFound` ends the request as ``RequestEnd/gone`` first, as ``ConnectionsManager``
    /// does (off by default).
    public var goneOnNotFound = false

    public init() {}

    private func call(_ name: String) throws {
        calls.append(name)
        if let f = fail.removeValue(forKey: name) { throw f }
    }

    public func refresh() async throws { try call("refresh") }

    public func connection(_ id: String) async throws -> ConnectionInfo {
        try call("connection")
        guard let c = connections.first(where: { $0.id == id }) else { throw VaultFailure(.notFound) }
        return c
    }

    public func inviteTtls() async throws -> [InviteTtl] {
        try call("inviteTtls")
        return ttls
    }

    public func createInvite(_ ttl: InviteTtl) async throws -> InviteInfo {
        try call("createInvite")
        var i = invite
        i.remote = ttl.remote
        return i
    }

    public func outstandingInvites() async throws -> [OutstandingInvite] {
        try call("outstandingInvites")
        return outstanding
    }

    public func cancelInvite(_ inviteID: String) async throws {
        try call("cancelInvite")
        outstanding.removeAll { $0.inviteID == inviteID }
    }

    /// Refuses what ``InviteLinks`` refuses, except the text `test-link`.
    public func acceptInvite(_ text: String) async throws -> AcceptedConnection {
        try call("acceptInvite")
        lastText = text
        switch InviteLinks.parse(text) {
        case .ok: break
        case .expired: throw VaultFailure(.inviteExpired)
        case .notAConnection: throw VaultFailure(.inviteNotConnection)
        case .invalid: if text != "test-link" { throw VaultFailure(.inviteInvalid) }
        }
        return acceptResult
    }

    private func edit(_ id: String, _ f: (inout ConnectionInfo) -> Void) {
        guard let i = connections.firstIndex(where: { $0.id == id }) else { return }
        f(&connections[i])
        connections[i].version += 1
    }

    public func setFavorite(_ id: String, favorite: Bool) async throws {
        try call("setFavorite")
        edit(id) { $0.favorite = favorite }
    }

    public func remove(_ id: String) async throws {
        try call("remove")
        connections.removeAll { $0.id == id }
    }

    public func block(_ id: String) async throws {
        try call("block")
        connections.removeAll { $0.id == id }
    }

    public func setAsksMuted(_ id: String, muted: Bool) async throws {
        try call("asksMute:\(id):\(muted)")
        edit(id) { $0.asks = ($0.asks ?? AskState()).muted(muted) }
    }

    public func resumeAsks(_ id: String) async throws {
        try call("asksResume:\(id)")
        edit(id) { $0.asks = ($0.asks ?? AskState()).resumed() }
    }

    public func dismissPeerDecline(_ requestID: String) {
        calls.append("dismissPeerDecline")
        peerDeclines.removeAll { $0.requestID == requestID }
    }

    public func refreshRequests() async throws { try call("refreshRequests") }

    /// A decision on request [id]: with ``goneOnNotFound``, a `notFound` failure ends it as ``RequestEnd/gone``.
    private func decide(_ name: String, _ id: String) throws {
        do {
            try call(name)
        } catch let f as VaultFailure where goneOnNotFound && f.kind == .notFound {
            end(id, .gone)
            throw f
        }
    }

    private func end(_ id: String, _ e: RequestEnd) {
        requests.removeAll { $0.id == id }
        requestEnds[id] = e
    }

    private func approve(_ id: String) {
        guard let i = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[i] = requests[i].with(state: .approved)
    }

    public func approveConnection(_ pendingID: String) async throws {
        try decide("approveConnection", pendingID)
        approve(pendingID)
    }

    public func declineConnection(_ pendingID: String) async throws {
        try decide("declineConnection", pendingID)
        end(pendingID, .declined)
    }

    public func blockConnectionRequest(_ pendingID: String) async throws {
        try decide("blockConnectionRequest", pendingID)
        end(pendingID, .declined)
    }

    public func approveOutgoing(_ connectionID: String) async throws {
        try decide("approveOutgoing", connectionID)
        approve(connectionID)
    }

    public func declineOutgoing(_ connectionID: String) async throws {
        try decide("declineOutgoing", connectionID)
        end(connectionID, .declined)
    }
}
