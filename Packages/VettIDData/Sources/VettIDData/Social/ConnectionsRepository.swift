import Foundation
import Observation

/// Connections and invitations (VAULT-MESSAGING §6.4, §10.4, §10.4.1), as ``Repositories.swift`` describes the
/// repositories: a `@MainActor` protocol whose state an `@Observable` type holds. Every failure is a ``VaultFailure``.
/// Mirrors vettid-android `ConnectionsRepository` (its member authentication comes with the approvals, IOS-PLAN §8 I2.3).
@MainActor
public protocol ConnectionsRepository: AnyObject, Observable, Sendable {
    /// The vault's connections, as last read (re-read on connection events).
    var connections: [ConnectionInfo] { get }

    func refresh() async throws

    func connection(_ id: String) async throws -> ConnectionInfo

    /// The invite lifetimes the relay allows (§6.4: never above its open-token and claim limits).
    func inviteTtls() async throws -> [InviteTtl]

    func createInvite(_ ttl: InviteTtl) async throws -> InviteInfo

    func outstandingInvites() async throws -> [OutstandingInvite]

    func cancelInvite(_ inviteID: String) async throws

    /// Accepts a pasted or opened link or a scanned QR code (every form of §6.4, ``InviteLinks``): an outgoing request,
    /// or ``AcceptedConnection/exists`` when this vault is already connected to (or requesting) the inviter.
    func acceptInvite(_ text: String) async throws -> AcceptedConnection

    func setFavorite(_ id: String, favorite: Bool) async throws

    func remove(_ id: String) async throws

    /// Removes the connection and blocks its identity (§10.4 block list).
    func block(_ id: String) async throws

    /// Mutes or unmutes the connection's asks (`connection.asks.mute`, VAULT-MESSAGING 0.23.0 §10.4.1).
    func setAsksMuted(_ id: String, muted: Bool) async throws

    /// Resumes the connection's paused asks and clears its cooldowns (`connection.asks.resume`, §10.4.1).
    func resumeAsks(_ id: String) async throws
}

/// Connection requests of either side (§6.4, §10.4: 0.10.2–0.10.6) and their safety codes: the part of vettid-android's
/// `ApprovalsRepository` that connecting needs. The other approvals (§10.12, §10.13, §6.8) come with the Approvals screen
/// (IOS-PLAN §8 I2.3), which lists these with them by ``PendingConnection/key``.
@MainActor
public protocol ConnectionRequestsRepository: AnyObject, Observable, Sendable {
    /// The open requests, newest first; expired ones are left out.
    var requests: [PendingConnection] { get }

    /// Requests that ended without a connection, by request id (`pending_id` incoming, `connection_id` outgoing), as
    /// this app learned it.
    var requestEnds: [String: RequestEnd] { get }

    /// Requests the other member declined (0.10.5), oldest first, until ``dismissPeerDecline(_:)``.
    var peerDeclines: [PeerDecline] { get }

    /// The member has seen that the other member declined [requestID]: it is not shown again.
    func dismissPeerDecline(_ requestID: String)

    /// Re-reads the connection requests (`connection.request.list`, §10.4).
    func refreshRequests() async throws

    /// Approves an incoming request (the inviter's side) after comparing the safety code.
    func approveConnection(_ pendingID: String) async throws

    func declineConnection(_ pendingID: String) async throws

    /// Declines the request and blocks the requester's identity (a block looks like a decline to the peer).
    func blockConnectionRequest(_ pendingID: String) async throws

    /// Approves this vault's outgoing request (the accepter's side) after comparing the safety code.
    func approveOutgoing(_ connectionID: String) async throws

    /// Declines this vault's outgoing request; the vault tells the inviter's vault when it can (`connection.declined`,
    /// 0.10.5).
    func declineOutgoing(_ connectionID: String) async throws
}
