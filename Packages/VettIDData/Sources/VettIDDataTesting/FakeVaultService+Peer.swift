#if DEBUG
import Foundation
import VettIDCrypto

// Fixtures (JSON bodies of the fake vault) stay on one line each.
// swiftlint:disable line_length

// TEST ONLY. The other member's vault, emulated (VAULT-MESSAGING §6.4, 0.10.3–0.10.6): what its steps make this vault
// do and tell this phone, as vettid-vault's `newRequest`, `outgoingEstablished`, `peerApproved`, `peerDeclined` and
// `activate` do: `connection.request.pending` once the accepter's `hs.fin` checked out, `connection.request.outgoing`
// once this vault sent its `hs.fin`, `sync.event{connection.request}` for the peer's approval and decline, and
// `connection.event{added}` once both members approved.
extension FakeVaultService {
    /// The safety code of a handshake: six digits.
    static func newSAS() -> String {
        String(format: "%06d", Int(Randomness.bytes(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000))
    }

    static func newPeer(first: String, last: String, name: String?) -> FakeSocial.Peer {
        FakeSocial.Peer(ik: Ed25519PrivateKey.generate().publicKey, firstName: first, lastName: last, name: name)
    }

    // MARK: - Another member invites this one

    /// Another member's invitation (§6.4): the bare link, on its own relay, whose claim this vault can fetch once. Its
    /// bundle's `hint.name` is [name]; [remote] for a lifetime above 10 minutes.
    public func peerInvite(first: String = "Morgan", last: String = "Lee", name: String? = "Morgan", remote: Bool = false, ttl: TimeInterval = 600) throws -> String {
        try locked {
            let claim = Self.claimID()
            social.claims[claim] = (Self.newPeer(first: first, last: last, name: name), remote)
            return try Self.inviteLink(relay: "https://relay.peer.example", claimID: claim, exp: Date().addingTimeInterval(ttl))
        }
    }

    /// An invitation of the same member as the connection or request [id] (the same vault identity).
    public func peerInvite(sameAs id: String) throws -> String {
        try locked {
            guard let peer = social.connections[id]?.peer ?? social.requests[id]?.peer else { throw CryptoError.format("unknown peer") }
            let claim = Self.claimID()
            social.claims[claim] = (peer, false)
            return try Self.inviteLink(relay: "https://relay.peer.example", claimID: claim, exp: Date().addingTimeInterval(600))
        }
    }

    /// Accepts hold the inviter's `hs.resp` until ``runHandshake(_:)`` (the outgoing request stays `waiting`).
    public var holdsHandshakes: Bool {
        get { locked { social.holdHandshakes } }
        set { locked { social.holdHandshakes = newValue } }
    }

    /// The inviter's `hs.resp` arrives for the outgoing request [connectionID]: this vault sends `hs.fin` and its devices
    /// get the safety code (`connection.request.outgoing`).
    public func runHandshake(_ connectionID: String) throws {
        try locked { try handshakeRan(connectionID) }
    }

    /// Callers hold ``cond``.
    func handshakeRan(_ id: String) throws {
        guard var r = social.requests[id], !r.incoming, r.sas == nil else { return }
        r.sas = Self.newSAS()
        social.requests[id] = r
        var b = JsonBuilder().string("connection_id", r.id).string("sas", r.sas ?? "").bool("remote", r.remote).string("exp", Timestamps.formatMillis(r.exp))
        if let n = r.name { b = b.string("name", n) }
        try reply("connection.request.outgoing", b.build())
    }

    // MARK: - Another member accepts this member's invitation

    /// Another member accepted the invitation [inviteID] (the latest outstanding one without it) and the handshake checked
    /// out: the invitation is spent and this phone gets `connection.request.pending` with the safety code. Returns the
    /// `pending_id`.
    @discardableResult
    public func peerAccepts(_ inviteID: String? = nil, first: String = "Alex", last: String = "Kim", name: String? = nil) throws -> String {
        try locked {
            guard let inv = inviteID.flatMap({ social.invites[$0] }) ?? social.invites.values.max(by: { $0.id < $1.id }) else {
                throw CryptoError.format("no outstanding invitation")
            }
            social.invites[inv.id] = nil
            let now = Date()
            let r = FakeSocial.Request(id: Ulid.new(), incoming: true, sas: Self.newSAS(), remote: inv.remote, created: now, exp: now.addingTimeInterval(Self.incomingTtl), inviteID: inv.id, peer: Self.newPeer(first: first, last: last, name: name))
            social.requests[r.id] = r
            try reply("connection.request.pending", incomingJSON(r, list: false))
            return r.id
        }
    }

    // MARK: - The other member decides

    /// The other member approved request [id] (`connection.approved` arrived): the connection is made if this member
    /// approved too, else this phone is told (`sync.event{connection.request, state: "peer_approved"}`).
    public func peerApproves(_ id: String) throws {
        try locked {
            guard var r = social.requests[id], r.sas != nil, !r.peerApproved else { return }
            r.peerApproved = true
            social.requests[id] = r
            if r.approved { return try activate(r) }
            try reply("sync.event", requestSync(r, "peer_approved"))
        }
    }

    /// The other member declined request [id] (`connection.declined`, 0.10.5): it ends, and this phone is told; an outgoing
    /// request also fails (`connection.event{failed, reason: "declined"}`).
    public func peerDeclines(_ id: String) throws {
        try locked {
            guard let r = social.requests.removeValue(forKey: id) else { return }
            try reply("sync.event", requestSync(r, "peer_declined"))
            if !r.incoming { try reply("connection.event", #"{"connection_id":"\#(r.id)","event":"failed","reason":"declined"}"#) }
        }
    }

    /// The connection's member changed their shared profile (`profile.update`, §10.8): `connection.event{profile}`.
    public func peerProfileChanged(_ connectionID: String, name: String?) throws {
        try locked {
            guard var c = social.connections[connectionID] else { return }
            c.peer.name = name
            c.profile = c.peer.profile(version: 2)
            social.connections[connectionID] = c
            try reply("connection.event", #"{"connection_id":"\#(connectionID)","event":"profile"}"#)
        }
    }

    func requestSync(_ r: FakeSocial.Request, _ state: String) -> String {
        JsonBuilder().string("kind", "connection.request").string(r.incoming ? "pending_id" : "connection_id", r.id).string("state", state).build()
    }

    /// Both members approved: the request leaves the list and the connection is active (`connection.event{added}`, with
    /// the `pending_id` on the inviter's side). The peer's first `profile.update` follows at once. Callers hold ``cond``.
    func activate(_ r: FakeSocial.Request) throws {
        social.requests[r.id] = nil
        let id = r.incoming ? Ulid.new() : r.id
        social.connections[id] = FakeSocial.Connection(id: id, peer: r.peer, profile: r.peer.profile(version: 1), created: Date())
        let pending = r.incoming ? #","pending_id":"\#(r.id)""# : ""
        try reply("connection.event", #"{"connection_id":"\#(id)","event":"added"\#(pending)}"#)
    }

    // MARK: - What the test reads

    /// The requests this vault sent `connection.approved` and `connection.declined` for, in order.
    public var approvedSent: [String] { locked { social.approvedSent } }
    public var declinedSent: [String] { locked { social.declinedSent } }

    /// The safety code of the open request [id] (what the other member's screen shows).
    public func sas(of id: String) -> String? { locked { social.requests[id]?.sas } }

    /// The ids of the vault's connections, sorted.
    public var connectionIDs: [String] { locked { social.connections.keys.sorted() } }

    /// The vault's outstanding invitations, by id.
    public var inviteIDs: [String] { locked { social.invites.keys.sorted() } }

    /// The block list's identity keys.
    public var blockedKeys: [[UInt8]] { locked { Array(social.blocks.values) } }
}

// swiftlint:enable line_length
#endif
