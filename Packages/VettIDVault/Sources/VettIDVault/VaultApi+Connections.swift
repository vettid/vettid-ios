import Foundation
import VettIDCrypto
import VettIDRelay

// Connections and invitations (VAULT-MESSAGING §6.4, §10.4), blocks (§10.4 "Block list") and a connection's asks
// (§10.4.1): one function per type. The member authentication of §10.4 comes with the approvals (IOS-PLAN §8 I2.3).
// Mirrors the connection part of vettid-android `VaultApi` and `VaultApiAsks`.
extension VaultApi {
    /// The lifetimes of §6.4, in seconds: 10 minutes in person; 1 hour, 24 hours and 7 days remote.
    public static let inviteTtls: [Int] = [600, 3_600, 86_400, 604_800]

    private func connectionOp(_ type: String, _ body: JsonBuilder = JsonBuilder()) async throws -> JsonObject {
        VaultJSON.object(try await device.op(type, body: body.bytes()))
    }

    /// The relay's limits: an invite lifetime above `open_token_max_lifetime_seconds` or `claim_ttl_seconds` is not
    /// offered (§6.4).
    public func relayLimits() async throws -> RelayLimits { try await device.relayLimits() }

    /// `connection.invite.create` (app only): [ttlSeconds] is one of ``inviteTtls``; `ttl_not_allowed` above the relay's
    /// limits.
    public func inviteCreate(ttlSeconds: Int) async throws -> Invite {
        let o = try await connectionOp("connection.invite.create", JsonBuilder().uint("ttl_seconds", UInt64(max(ttlSeconds, 0))))
        guard let id = VaultJSON.string(o, "invite_id"), let link = VaultJSON.string(o, "link") else {
            throw VaultStateError(message: "invite without id or link")
        }
        return Invite(inviteID: id, link: link, exp: VaultJSON.string(o, "exp") ?? "", remote: VaultJSON.bool(o, "remote") ?? false)
    }

    /// `connection.invite.list`: `{invites: [{invite_id, exp, remote}]}`, the outstanding invitations.
    public func inviteList() async throws -> JsonObject { try await connectionOp("connection.invite.list") }

    /// `connection.invite.cancel`: the vault denylists the open token and deletes the claim; `not_found` for an unknown one.
    public func inviteCancel(_ inviteID: String) async throws {
        _ = try await connectionOp("connection.invite.cancel", JsonBuilder().string("invite_id", inviteID))
    }

    /// `connection.invite.accept` (app only) with the bare payload (§6.4): an outgoing request in state `waiting`. A vault
    /// already connected to the inviter, or with an outgoing request to it, answers `exists` with `{connection_id}`
    /// (``VaultOpError/body``).
    public func inviteAccept(_ link: String) async throws -> AcceptedInvite {
        let o = try await connectionOp("connection.invite.accept", JsonBuilder().string("link", link))
        guard let id = VaultJSON.string(o, "connection_id") else { throw VaultStateError(message: "accept without connection_id") }
        return AcceptedInvite(
            connectionID: id, state: VaultJSON.string(o, "state") ?? "waiting", remote: VaultJSON.bool(o, "remote") ?? false,
            exp: VaultJSON.string(o, "exp"), name: VaultJSON.string(o, "name")
        )
    }

    /// `connection.approve{pending_id}` (app only): approves an incoming request (the inviter's side) after comparing the
    /// safety code.
    public func connectionApprove(pendingID: String) async throws {
        _ = try await connectionOp("connection.approve", JsonBuilder().string("pending_id", pendingID))
    }

    /// `connection.decline{pending_id}`: declines an incoming request in any state (since 0.10.5 the vault tells the peer
    /// when it can, §6.4).
    public func connectionDecline(pendingID: String) async throws {
        _ = try await connectionOp("connection.decline", JsonBuilder().string("pending_id", pendingID))
    }

    /// `connection.approve{connection_id}` (app only): approves this vault's outgoing request (the accepter's side);
    /// `bad_request` while it is `waiting`.
    public func outgoingApprove(connectionID: String) async throws {
        _ = try await connectionOp("connection.approve", JsonBuilder().string("connection_id", connectionID))
    }

    /// `connection.decline{connection_id}`: declines this vault's outgoing request, in any state, `waiting` included.
    public func outgoingDecline(connectionID: String) async throws {
        _ = try await connectionOp("connection.decline", JsonBuilder().string("connection_id", connectionID))
    }

    /// `connection.request.list`: `{incoming: [...], outgoing: [...]}`, newest first, with their safety codes.
    public func requestList() async throws -> JsonObject { try await connectionOp("connection.request.list") }

    /// `connection.list`; an entry without its `id` or `state` is left out.
    public func connectionList() async throws -> [Connection] {
        VaultJSON.objects(try await connectionOp("connection.list"), "connections").compactMap(Connection.of)
    }

    /// `connection.get`; `not_found` for an unknown one.
    public func connectionGet(_ connectionID: String) async throws -> Connection {
        let o = try await connectionOp("connection.get", JsonBuilder().string("connection_id", connectionID))
        guard let c = Connection.of(o) else { throw VaultStateError(message: "connection without id or state") }
        return c
    }

    /// `connection.update` of the owner's own metadata against [version] (`conflict` when another device changed it
    /// first). Returns the new version.
    public func connectionUpdate(_ connectionID: String, version: Int64, change: ConnectionMetaChange) async throws -> Int64 {
        let b = JsonBuilder().string("connection_id", connectionID).uint("version", UInt64(max(version, 0)))
        if let a = change.alias { b.string("alias", a) }
        if let n = change.note { b.string("note", n) }
        if let t = change.tags { b.raw("tags", JsonBuilder.array(t.map(JsonBuilder.quote))) }
        if let f = change.favorite { b.bool("favorite", f) }
        if let a = change.archived { b.bool("archived", a) }
        return VaultJSON.int(try await connectionOp("connection.update", b), "version") ?? 0
    }

    /// `connection.remove` (§7.4 "Connection removed").
    public func connectionRemove(_ connectionID: String) async throws {
        _ = try await connectionOp("connection.remove", JsonBuilder().string("connection_id", connectionID))
    }

    /// `block.add` of a connection or of a pending request's sender, exactly one of the two; returns the block id.
    public func blockAdd(connectionID: String? = nil, pendingID: String? = nil, note: String? = nil) async throws -> String {
        let b = JsonBuilder()
        if let c = connectionID { b.string("connection_id", c) }
        if let p = pendingID { b.string("pending_id", p) }
        if let n = note { b.string("note", n) }
        return VaultJSON.string(try await connectionOp("block.add", b), "block_id") ?? ""
    }

    public func blockRemove(_ blockID: String) async throws {
        _ = try await connectionOp("block.remove", JsonBuilder().string("block_id", blockID))
    }

    /// `block.list`: `{blocks: [{block_id, ik, name?, note?, created_at}]}`.
    public func blockList() async throws -> JsonObject { try await connectionOp("block.list") }

    /// `connection.asks.mute` (0.23.0 §10.4.1): mutes or unmutes the connection's asks; `not_found`.
    public func connectionAsksMute(_ connectionID: String, muted: Bool) async throws {
        _ = try await connectionOp("connection.asks.mute", JsonBuilder().string("connection_id", connectionID).bool("muted", muted))
    }

    /// `connection.asks.resume` (§10.4.1): ends a pause and clears the declines and cooldowns; `not_found`.
    public func connectionAsksResume(_ connectionID: String) async throws {
        _ = try await connectionOp("connection.asks.resume", JsonBuilder().string("connection_id", connectionID))
    }
}
