import Foundation

/// An incoming connection request (§6.4, §10.4): `connection.request.pending`, or an entry of `connection.request.list`'s
/// `incoming`. The inviter approves or declines it after comparing [sas] with the code on the other member's screen.
/// Mirrors vettid-android `Approval.ConnectionRequest`.
public struct ConnectionRequest: Equatable, Sendable {
    public var pendingID: String
    public var inviteID: String?
    /// The safety code, six digits (§6.3).
    public var sas: String
    public var remote: Bool
    /// The requester's "First Last" from its `hs.init` profile (VAULT-MESSAGING 0.18.0 §6.2, §10.8): the names on its
    /// VettID account, not verified; nil when the profile carries none.
    public var name: String?
    public var introducedBy: String?
    public var receivedAt: Date
    public var exp: Date?
    /// ``RequestState/pending``, or ``RequestState/approved`` (by this member, or by in-person auto-approval).
    public var state: RequestState = .pending
    /// The other member approved too (their vault's `connection.approved` arrived).
    public var peerApproved = false
    /// The requester's self-asserted display name (`profile.name`), if any and different from [name].
    public var displayName: String?

    public init(pendingID: String, sas: String, remote: Bool, name: String?, receivedAt: Date, exp: Date?) {
        self.pendingID = pendingID
        self.sas = sas
        self.remote = remote
        self.name = name
        self.receivedAt = receivedAt
        self.exp = exp
    }
}

/// This vault's outgoing request (§6.4, 0.10.2/0.10.3): an invitation this member accepted. Once the handshake has run
/// its [sas] is known and the member approves or declines after comparing it with the inviter's screen. Mirrors
/// vettid-android `Approval.OutgoingRequest`.
public struct OutgoingRequest: Equatable, Sendable {
    public var connectionID: String
    public var sas: String?
    public var remote: Bool
    /// The inviter's name from the invitation (`hint.name`).
    public var name: String?
    public var state: RequestState
    public var peerApproved = false
    public var introducedBy: String?
    public var receivedAt: Date
    public var exp: Date?

    public init(connectionID: String, sas: String?, remote: Bool, name: String?, state: RequestState, receivedAt: Date, exp: Date?) {
        self.connectionID = connectionID
        self.sas = sas
        self.remote = remote
        self.name = name
        self.state = state
        self.receivedAt = receivedAt
        self.exp = exp
    }
}

/// A connection request of either side, as the Approvals screen lists it. [key] is stable and unique across the kinds of
/// approval (`connection:<pending_id>`, `outgoing:<connection_id>`, as vettid-android's), so that the other approvals
/// (IOS-PLAN §8 I2.3) join the same list.
public enum PendingConnection: Equatable, Sendable {
    case incoming(ConnectionRequest)
    case outgoing(OutgoingRequest)

    /// The request's id: `pending_id` incoming, `connection_id` outgoing.
    public var id: String {
        switch self {
        case .incoming(let r): r.pendingID
        case .outgoing(let r): r.connectionID
        }
    }

    public var key: String {
        switch self {
        case .incoming(let r): "connection:\(r.pendingID)"
        case .outgoing(let r): "outgoing:\(r.connectionID)"
        }
    }

    /// The name the request shows (self-asserted): the requester's account names, or the inviter's `hint.name`.
    public var name: String? {
        switch self {
        case .incoming(let r): r.name
        case .outgoing(let r): r.name
        }
    }

    public var sas: String? {
        switch self {
        case .incoming(let r): r.sas
        case .outgoing(let r): r.sas
        }
    }

    public var state: RequestState {
        switch self {
        case .incoming(let r): r.state
        case .outgoing(let r): r.state
        }
    }

    public var peerApproved: Bool {
        switch self {
        case .incoming(let r): r.peerApproved
        case .outgoing(let r): r.peerApproved
        }
    }

    public var receivedAt: Date {
        switch self {
        case .incoming(let r): r.receivedAt
        case .outgoing(let r): r.receivedAt
        }
    }

    public var exp: Date? {
        switch self {
        case .incoming(let r): r.exp
        case .outgoing(let r): r.exp
        }
    }

    /// Whether the member has something to decide: the safety code is known and this member has not approved yet.
    /// Requests waiting for the handshake or for the other member are shown but not counted.
    public var needsDecision: Bool { state == .pending }

    /// The request after this member's approval, or the peer's (§10.4: a request with both leaves the list).
    public func with(state s: RequestState? = nil, peerApproved p: Bool? = nil) -> PendingConnection {
        switch self {
        case .incoming(var r):
            if let s { r.state = s }
            if let p { r.peerApproved = p }
            return .incoming(r)
        case .outgoing(var r):
            if let s { r.state = s }
            if let p { r.peerApproved = p }
            return .outgoing(r)
        }
    }

    /// [newer] (a request event, or the list) over this one: an event never takes back what a decision already moved on
    /// (approved stays approved), and an outgoing request keeps its name.
    func merged(_ newer: PendingConnection) -> PendingConnection {
        let next = newer.with(state: max(state, newer.state), peerApproved: peerApproved || newer.peerApproved)
        if case .outgoing(var n) = next, case .outgoing(let old) = self, n.name == nil {
            n.name = old.name
            return .outgoing(n)
        }
        return next
    }
}

/// How long an unanswered incoming connection request is kept (§6.4: 7 days).
public let connectionRequestTtl: TimeInterval = 7 * 86_400
