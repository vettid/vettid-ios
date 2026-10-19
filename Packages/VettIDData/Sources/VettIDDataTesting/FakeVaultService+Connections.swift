#if DEBUG
import Foundation
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

/// TEST ONLY. The fake vault's connections (VAULT-MESSAGING §6.4, §10.4, §10.4.1): its invitations, connection requests
/// of both sides, connections and blocks, answered with the shapes, codes and events of vettid-vault's handlers
/// (`vault/core.go`, `vault/requests.go`, `vault/connections.go`, `vault/asks.go`). The other vault is emulated
/// (FakeVaultService+Peer.swift): no second handshake runs, but each of its steps reaches this vault as the real one's
/// would. Events the vault sends to every device but the one that asked (`notifyDevices` with the sender excluded) are
/// not sent, since the fake has one phone.
struct FakeSocial {
    struct Invite {
        var id: String
        var exp: Date
        var remote: Bool
    }

    struct Request {
        var id: String
        var incoming: Bool
        /// The safety code; nil while an outgoing request waits for its handshake.
        var sas: String?
        var remote: Bool
        var approved = false
        var peerApproved = false
        var created: Date
        var exp: Date
        /// The inviter's `hint.name` (outgoing).
        var name: String?
        var inviteID: String?
        var peer: Peer
    }

    /// The other vault: its identity key and its member's names (the shared profile's core and display name).
    struct Peer {
        var ik: [UInt8]
        var firstName: String
        var lastName: String
        var name: String?

        var hsInitProfile: String {
            var b = JsonBuilder().string("first_name", firstName).string("last_name", lastName)
            if let name { b = b.string("name", name) }
            return b.build()
        }

        func profile(version: UInt64) -> String {
            var b = JsonBuilder().uint("version", version).string("first_name", firstName).string("last_name", lastName).base64("ik", ik)
            if let name { b = b.string("name", name) }
            return b.raw("items", "[]").build()
        }
    }

    struct Connection {
        var id: String
        var peer: Peer
        var profile: String?
        var created: Date
        var version: UInt64 = 0
        var favorite = false
        var archived = false
        var tags: [String] = []
        var muted = false
        var paused = false
        var cooldowns = 0

        var json: String {
            var b = JsonBuilder().string("id", id).string("kind", "connection").string("state", "active").string("name", peer.name ?? "").base64("ik", peer.ik)
            if let profile { b = b.raw("profile", profile) }
            b = b.string("created_at", Timestamps.formatMillis(created)).uint("version", version)
            if !tags.isEmpty { b = b.raw("tags", JsonBuilder.array(tags.map(JsonBuilder.quote))) }
            b = b.bool("favorite", favorite).bool("archived", archived)
            let asks = JsonBuilder().bool("muted", muted).bool("paused", paused).uint("cooldowns", UInt64(cooldowns))
            return b.raw("asks", asks.build()).build()
        }
    }

    /// The invitations this vault made, outstanding (§10.4 `connection.invite.list`).
    var invites: [String: Invite] = [:]
    /// The other vaults' invitations by claim id: what a claim fetch would find (single fetch).
    var claims: [String: (peer: Peer, remote: Bool)] = [:]
    var requests: [String: Request] = [:]
    var connections: [String: Connection] = [:]
    var blocks: [String: [UInt8]] = [:]
    /// The emulated peer runs its handshake at once after an accept (0.10.3), unless the test holds it.
    var holdHandshakes = false
    /// What this vault sent the other vaults: `connection.approved` and `connection.declined`, by request id.
    var approvedSent: [String] = []
    var declinedSent: [String] = []
}

extension FakeVaultService {
    /// §6.4: in-person 10 minutes; remote 1 h, 24 h, 7 days, at most the relay's limits (here 24 h).
    static let relayInviteLimit: UInt64 = 86_400
    static let outgoingTtl: TimeInterval = 8 * 86_400
    static let incomingTtl: TimeInterval = 7 * 86_400

    /// The connection requests (§10.4, §10.4.1); `unsupported_type` for any other. Callers hold ``cond``.
    func connectionsRequest(_ m: Inner, _ body: JsonObject) throws { // swiftlint:disable:this cyclomatic_complexity
        switch m.type {
        case "connection.invite.create": try inviteCreate(m, body)
        case "connection.invite.list":
            let list = social.invites.values.sorted { $0.id < $1.id }.map { JsonBuilder().string("invite_id", $0.id).string("exp", Self.wholeSeconds($0.exp)).bool("remote", $0.remote).build() }
            try reply(m.type, #"{"invites":\#(JsonBuilder.array(list))}"#, re: m.id)
        case "connection.invite.cancel":
            let id = try body.string("invite_id")
            guard social.invites.removeValue(forKey: id) != nil else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            try reply(m.type, "{}", re: m.id)
        case "connection.invite.accept": try inviteAccept(m, body)
        case "connection.approve": try approve(m, body)
        case "connection.decline": try decline(m, body)
        case "connection.request.list": try reply(m.type, requestList(), re: m.id)
        case "connection.list":
            let list = social.connections.keys.sorted().compactMap { social.connections[$0]?.json }
            try reply(m.type, #"{"connections":\#(JsonBuilder.array(list))}"#, re: m.id)
        case "connection.get":
            guard let c = social.connections[try body.string("connection_id")] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            try reply(m.type, c.json, re: m.id)
        case "connection.update": try connectionUpdate(m, body)
        case "connection.remove":
            guard let c = social.connections.removeValue(forKey: try body.string("connection_id")) else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            try reply(m.type, "{}", re: m.id)
            try reply("connection.event", #"{"connection_id":"\#(c.id)","event":"removed"}"#)
        case "block.add": try blockAdd(m, body)
        case "block.list":
            let list = social.blocks.keys.sorted().compactMap { id in social.blocks[id].map { JsonBuilder().string("block_id", id).base64("ik", $0).string("created_at", Timestamps.formatMillis(Date())).build() } }
            try reply(m.type, #"{"blocks":\#(JsonBuilder.array(list))}"#, re: m.id)
        case "block.remove":
            guard social.blocks.removeValue(forKey: try body.string("block_id")) != nil else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            try reply(m.type, "{}", re: m.id)
        case "connection.asks.mute", "connection.asks.resume": try asks(m, body)
        default: try reply(m.type, "{}", re: m.id, error: "unsupported_type")
        }
    }

    static func wholeSeconds(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// A link as `connection.invite.create` makes it (§6.4): the QR payload on [relay], base64url.
    static func inviteLink(relay: String, claimID: String, exp: Date) throws -> String {
        try InviteQr(kind: .connection, relay: relay, claimID: claimID, hash: Randomness.bytes(32), key: Randomness.bytes(32), exp: UInt64(exp.timeIntervalSince1970)).link()
    }

    static func claimID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        return String(Randomness.bytes(InviteQr.claimIDLength).map { alphabet[Int($0) % alphabet.count] })
    }

    /// `connection.invite.create` (vettid-vault `hInviteCreate`): `bad_request` outside 1 s–30 days, `ttl_not_allowed`
    /// above the relay's limits; remote above 10 minutes.
    private func inviteCreate(_ m: Inner, _ body: JsonObject) throws {
        guard let ttl = try? body.uint("ttl_seconds", min: 1, max: 30 * 86_400) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard ttl <= Self.relayInviteLimit else { return try reply(m.type, "{}", re: m.id, error: "ttl_not_allowed") }
        let exp = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + Double(ttl)).rounded(.down))
        let inv = FakeSocial.Invite(id: Ulid.new(), exp: exp, remote: ttl > 600)
        social.invites[inv.id] = inv
        let link = try Self.inviteLink(relay: vaultRelay.baseURL, claimID: Self.claimID(), exp: exp)
        try reply(m.type, JsonBuilder().string("invite_id", inv.id).string("link", link).string("exp", Self.wholeSeconds(exp)).bool("remote", inv.remote).build(), re: m.id)
    }

    /// `connection.invite.accept` (vettid-vault `acceptInvite`): the claim fetched once, `blocked`, `exists` with this
    /// vault's id for that peer, then the outgoing request `waiting`; the peer's `hs.resp` follows unless held.
    private func inviteAccept(_ m: Inner, _ body: JsonObject) throws {
        guard let q = try? InviteQr.parseLink(try body.string("link")), q.kind == .connection else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard let claim = social.claims.removeValue(forKey: q.claimID) else { return try reply(m.type, "{}", re: m.id, error: "claim_unavailable") }
        if social.blocks.values.contains(claim.peer.ik) { return try reply(m.type, "{}", re: m.id, error: "blocked") }
        if let existing = existingWith(claim.peer.ik) { return try reply(m.type, #"{"connection_id":"\#(existing)"}"#, re: m.id, error: "exists") }
        let now = Date()
        let r = FakeSocial.Request(id: Ulid.new(), incoming: false, sas: nil, remote: claim.remote, created: now, exp: now.addingTimeInterval(Self.outgoingTtl), name: claim.peer.name, peer: claim.peer)
        social.requests[r.id] = r
        var answer = JsonBuilder().string("connection_id", r.id).string("state", "waiting").bool("remote", r.remote).string("exp", Timestamps.formatMillis(r.exp))
        if let n = r.name { answer = answer.string("name", n) }
        try reply(m.type, answer.build(), re: m.id)
        if !social.holdHandshakes { try handshakeRan(r.id) }
    }

    /// The vault's connection or outgoing request with the peer of [ik] (§6.4 "Already connected").
    func existingWith(_ ik: [UInt8]) -> String? {
        social.connections.values.first { $0.peer.ik == ik }?.id ?? social.requests.values.first { !$0.incoming && $0.peer.ik == ik }?.id
    }

    /// `{pending_id}` or `{connection_id}`, exactly one (vettid-vault `requestRef`).
    private func requestRef(_ body: JsonObject) -> (id: String, incoming: Bool)? {
        let p = try? body.optString("pending_id"), c = try? body.optString("connection_id")
        switch (p ?? nil, c ?? nil) {
        case (let p?, nil): return (p, true)
        case (nil, let c?): return (c, false)
        default: return nil
        }
    }

    /// `connection.approve` (vettid-vault `hConnApprove`): `bad_request` while the SAS is not known, `not_found` for an
    /// unknown request; `connection.approved` to the peer, and the connection made once both approved.
    private func approve(_ m: Inner, _ body: JsonObject) throws {
        guard let ref = requestRef(body) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard var r = social.requests[ref.id], r.incoming == ref.incoming else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        guard r.sas != nil else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        try reply(m.type, "{}", re: m.id)
        guard !r.approved else { return }
        r.approved = true
        social.requests[r.id] = r
        social.approvedSent.append(r.id)
        if r.peerApproved { try activate(r) }
    }

    /// `connection.decline` (vettid-vault `hConnDecline`): accepted in any state; `connection.declined` to the peer once
    /// the vault holds the handshake's epoch and the peer's token (not while an outgoing request waits).
    private func decline(_ m: Inner, _ body: JsonObject) throws {
        guard let ref = requestRef(body) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        guard let r = social.requests[ref.id], r.incoming == ref.incoming else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        social.requests[r.id] = nil
        if r.sas != nil { social.declinedSent.append(r.id) }
        try reply(m.type, "{}", re: m.id)
    }

    /// `connection.request.list` (vettid-vault `hRequestList`): newest first; a waiting outgoing request without `sas`.
    private func requestList() -> String {
        let sorted = social.requests.values.sorted { $0.created == $1.created ? $0.id > $1.id : $0.created > $1.created }
        let incoming = sorted.filter(\.incoming).map { incomingJSON($0, list: true) }
        let outgoing = sorted.filter { !$0.incoming }.map { r in
            var b = JsonBuilder().string("connection_id", r.id)
            if let sas = r.sas { b = b.string("sas", sas) }
            b = b.bool("remote", r.remote).string("state", r.sas == nil ? "waiting" : (r.approved ? "approved" : "pending")).bool("peer_approved", r.peerApproved)
            b = b.string("created_at", Timestamps.formatMillis(r.created)).string("exp", Timestamps.formatMillis(r.exp))
            if let n = r.name { b = b.string("name", n) }
            return b.build()
        }
        return #"{"incoming":\#(JsonBuilder.array(incoming)),"outgoing":\#(JsonBuilder.array(outgoing))}"#
    }

    /// An incoming request as `connection.request.pending` (list: with `peer_approved` and `created_at`) shows it.
    func incomingJSON(_ r: FakeSocial.Request, list: Bool) -> String {
        var b = JsonBuilder().string("pending_id", r.id).string("invite_id", r.inviteID ?? "").string("sas", r.sas ?? "").bool("remote", r.remote).string("state", r.approved ? "approved" : "pending")
        if list { b = b.bool("peer_approved", r.peerApproved).string("created_at", Timestamps.formatMillis(r.created)) }
        return b.string("exp", Timestamps.formatMillis(r.exp)).raw("profile", r.peer.hsInitProfile).build()
    }

    /// `connection.update` (vettid-vault `hConnUpdate`): against the current version (`conflict`), at least one member.
    private func connectionUpdate(_ m: Inner, _ body: JsonObject) throws {
        guard var c = social.connections[try body.string("connection_id")] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        guard try body.uint("version", min: 0, max: StrictJson.maxSafeInteger) == c.version else { return try reply(m.type, "{}", re: m.id, error: "conflict") }
        let favorite = try? body.bool("favorite"), archived = try? body.bool("archived"), tags = try? body.array("tags")
        guard favorite != nil || archived != nil || tags != nil || body.has("alias") || body.has("note") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        if let favorite { c.favorite = favorite }
        if let archived { c.archived = archived }
        if let tags { c.tags = tags.compactMap { try? $0.asString() } }
        c.version += 1
        social.connections[c.id] = c
        try reply(m.type, #"{"version":\#(c.version)}"#, re: m.id)
    }

    /// `block.add` (vettid-vault `hBlockAdd`): a connection is removed (`connection.event{removed}`), a pending request
    /// declined; its identity is recorded (`exists` when it already is).
    private func blockAdd(_ m: Inner, _ body: JsonObject) throws {
        guard let ref = requestRef(body) else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
        let peer: FakeSocial.Peer
        if ref.incoming {
            guard let r = social.requests[ref.id], r.incoming else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            peer = r.peer
        } else {
            guard let c = social.connections[ref.id] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
            peer = c.peer
        }
        if social.blocks.values.contains(peer.ik) { return try reply(m.type, "{}", re: m.id, error: "exists") }
        let id = Ulid.new()
        social.blocks[id] = peer.ik
        try reply(m.type, #"{"block_id":"\#(id)"}"#, re: m.id)
        if ref.incoming {
            social.requests[ref.id] = nil
            social.declinedSent.append(ref.id)
        } else {
            social.connections[ref.id] = nil
            try reply("connection.event", #"{"connection_id":"\#(ref.id)","event":"removed"}"#)
        }
    }

    /// `connection.asks.mute` and `.resume` (vettid-vault `hAsksMute`, `hAsksResume`): `sync.event{connection.changed}` to
    /// every owner device, the asking one included.
    private func asks(_ m: Inner, _ body: JsonObject) throws {
        guard var c = social.connections[try body.string("connection_id")] else { return try reply(m.type, "{}", re: m.id, error: "not_found") }
        if m.type == "connection.asks.mute" {
            guard let muted = try? body.bool("muted") else { return try reply(m.type, "{}", re: m.id, error: "bad_request") }
            let changed = c.muted != muted
            c.muted = muted
            social.connections[c.id] = c
            try reply(m.type, "{}", re: m.id)
            if !changed { return }
        } else {
            c.paused = false
            c.cooldowns = 0
            social.connections[c.id] = c
            try reply(m.type, "{}", re: m.id)
        }
        try reply("sync.event", #"{"kind":"connection.changed","connection_id":"\#(c.id)","version":\#(c.version)}"#)
    }
}

// swiftlint:enable line_length
#endif
