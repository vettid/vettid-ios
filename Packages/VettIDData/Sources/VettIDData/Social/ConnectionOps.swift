import Foundation
import VettIDCrypto
import VettIDVault

/// The vault calls behind ``ConnectionsManager`` (VAULT-MESSAGING §10.4, §10.4.1), one per type, as ``VaultApi`` has
/// them; a test passes its own. Errors are the vault client's (``VaultOpError`` with the spec's code), mapped by the
/// manager.
public protocol ConnectionOps: Sendable {
    /// The longest invite lifetime the relay allows: the lower of its `open_token_max_lifetime_seconds` and
    /// `claim_ttl_seconds` (§6.4).
    func inviteLifetimeLimit() async throws -> UInt64
    func inviteCreate(ttlSeconds: Int) async throws -> Invite
    func inviteList() async throws -> JsonObject
    func inviteCancel(_ inviteID: String) async throws
    func inviteAccept(_ link: String) async throws -> AcceptedInvite
    func connectionApprove(pendingID: String) async throws
    func connectionDecline(pendingID: String) async throws
    func outgoingApprove(connectionID: String) async throws
    func outgoingDecline(connectionID: String) async throws
    func requestList() async throws -> JsonObject
    func connectionList() async throws -> [Connection]
    func connectionGet(_ connectionID: String) async throws -> Connection
    func connectionUpdate(_ connectionID: String, version: Int64, change: ConnectionMetaChange) async throws -> Int64
    func connectionRemove(_ connectionID: String) async throws
    func blockAdd(connectionID: String?, pendingID: String?, note: String?) async throws -> String
    func connectionAsksMute(_ connectionID: String, muted: Bool) async throws
    func connectionAsksResume(_ connectionID: String) async throws
}

extension VaultApi: ConnectionOps {
    public func inviteLifetimeLimit() async throws -> UInt64 {
        let l = try await relayLimits()
        return min(l.openTokenMaxLifetimeSeconds, l.claimTTLSeconds)
    }
}
