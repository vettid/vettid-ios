import Foundation

// The connections and connection requests as the app shows them (VAULT-MESSAGING §6.4, §10.4, §10.4.1, §10.8;
// ANDROID-PLAN §4). Mirrors the connection part of vettid-android `SocialModels.kt`: messages (§10.5) and the other
// approvals (§10.12, §10.13, §6.8) join them with their rows.

/// A connection's state as the app shows it (§10.4).
public enum ConnectionState: Equatable, Sendable {
    case active, pending, stale, blocked, other

    public static func of(_ wire: String) -> ConnectionState {
        switch wire {
        case "active": .active
        case "pending": .pending
        case "stale": .stale
        case "blocked": .blocked
        default: .other
        }
    }
}

/// A connection (§10.4). [firstName] and [lastName] are the names on the peer's VettID account, from the shared
/// profile's core (VAULT-MESSAGING 0.18.0 §10.8; on the inviter's side, before the first `profile.update`, from the
/// request): nil before they arrived, never verified. [name] (the display name), [photo] and [sharedItems] are the peer's
/// self-asserted extras; [favorite] and [archived] are the owner's own metadata, never sent to the peer. The owner's
/// alias and note (§10.4) are not read: the app neither shows nor sets them (as vettid-android); any a vault holds stay
/// there untouched.
public struct ConnectionInfo: Equatable, Sendable, Identifiable {
    public var id: String
    /// The peer's display name (optional); "" without one. Never the title on its own (§10.8).
    public var name: String
    public var state: ConnectionState
    public var favorite = false
    public var archived = false
    public var tags: [String] = []
    public var version: Int64 = 0
    public var firstName: String?
    public var lastName: String?
    /// The `@profile` items the peer shares, as the peer presents them.
    public var sharedItems: [SharedProfileItem] = []
    public var hasPhoto = false
    /// The peer's shared photo (§10.8, base64 JPEG or PNG, self-asserted); decoded defensively by the UI.
    public var photo: String?
    /// The fingerprint of the peer vault's pinned identity key (§10.8: 8 groups of 4 hex digits).
    public var keyFingerprint: String?
    public var createdAt: Date?
    public var lastActiveAt: Date?
    /// Whether the connection's asks are muted or paused (`<connection>.asks`, 0.23.0 §10.4.1); nil from an older vault.
    public var asks: AskState?

    public init(id: String, name: String, state: ConnectionState) {
        self.id = id
        self.name = name
        self.state = state
    }

    /// "First Last" from the names on the peer's account; nil before they arrived (§10.8).
    public var accountName: String? { AccountNames.full(firstName, lastName) }

    /// The title (§10.8): "First Last"; "" before the names arrived, for which the UI shows "Name not shared yet". Never
    /// the display name alone, never an alias.
    public var displayName: String { accountName ?? "" }

    /// The peer's display name when it adds something to the title (non-empty and different), for secondary text.
    /// Cleaned of control and format characters, and compared cleaned (VAULT-MESSAGING §10.8; mirrors vettid-android #220);
    /// the screens isolate it where it sits in a row.
    public var secondaryName: String? {
        guard let n = AccountNames.cleaned(name) else { return nil }
        return n == AccountNames.cleaned(displayName) || n == AccountNames.cleaned(accountName) ? nil : n
    }
}

/// A connection's asks as the member's vault holds them (VAULT-MESSAGING 0.23.0 §10.4.1): [muted] by the member,
/// [paused] (since [pausedAt]) after three declines within 30 days, and [cooldowns] declined asks refused for 7 days.
/// Muting and a pause only stop asks; messages, profile updates, grants and shares go on.
public struct AskState: Equatable, Sendable {
    public var muted = false
    public var paused = false
    public var pausedAt: Date?
    public var cooldowns = 0

    public init(muted: Bool = false, paused: Bool = false, pausedAt: Date? = nil, cooldowns: Int = 0) {
        self.muted = muted
        self.paused = paused
        self.pausedAt = pausedAt
        self.cooldowns = cooldowns
    }

    /// What the connection page offers: unmute (or mute), and resume while paused or with cooldowns.
    public var canResume: Bool { paused || cooldowns > 0 }

    /// After `connection.asks.mute{muted}`: unmuting does not resume a pause (§10.4.1).
    public func muted(_ on: Bool) -> AskState {
        var a = self
        a.muted = on
        return a
    }

    /// After `connection.asks.resume`: the pause ends and the declines and cooldowns are cleared; a mute stays.
    public func resumed() -> AskState { AskState(muted: muted) }
}

/// One `@profile` item of a peer's shared profile (§10.8): self-asserted. [fields] are (label, value) pairs.
public struct SharedProfileItem: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public var itemID: String
    public var name: String
    public var fields: [Field]

    public init(itemID: String, name: String, fields: [Field]) {
        self.itemID = itemID
        self.name = name
        self.fields = fields
    }
}

/// The invite lifetimes of §6.4: 10 minutes in person (the default), longer for remote invites.
public enum InviteTtl: Int, CaseIterable, Equatable, Sendable {
    case tenMinutes = 600
    case oneHour = 3_600
    case oneDay = 86_400
    case sevenDays = 604_800

    public var seconds: Int { rawValue }

    /// Remote invites stay pending until the inviter approves; auto-approval never applies (§6.4).
    public var remote: Bool { self != .tenMinutes }
}

/// A new invitation: [link] the bare payload, [qr] the compact JSON to show as a QR code, and ``url`` the invitation
/// URL to share (`<r>/connect#<link>` on the invitation's relay, §6.4).
public struct InviteInfo: Equatable, Sendable {
    public var inviteID: String
    public var link: String
    public var qr: String
    public var exp: Date
    public var remote: Bool

    public init(inviteID: String, link: String, qr: String, exp: Date, remote: Bool) {
        self.inviteID = inviteID
        self.link = link
        self.qr = qr
        self.exp = exp
        self.remote = remote
    }

    public var url: String { InviteLinks.url(link) ?? link }
}

/// An outstanding invitation (`connection.invite.list`).
public struct OutstandingInvite: Equatable, Sendable {
    public var inviteID: String
    public var exp: Date?
    public var remote: Bool

    public init(inviteID: String, exp: Date?, remote: Bool) {
        self.inviteID = inviteID
        self.exp = exp
        self.remote = remote
    }
}

/// `connection.invite.accept` (§6.4): the outgoing request [connectionID] (its safety code follows once the handshake
/// has run, 0.10.3) and the inviter's [name] from the invitation; or, with [exists], the connection (or request) this
/// vault already has with the inviter (0.10.2).
public struct AcceptedConnection: Equatable, Sendable {
    public var connectionID: String
    public var name: String?
    public var exists = false
    public var exp: Date?

    public init(connectionID: String, name: String? = nil, exists: Bool = false, exp: Date? = nil) {
        self.connectionID = connectionID
        self.name = name
        self.exists = exists
        self.exp = exp
    }
}

/// Where a connection request stands (§10.4, 0.10.3), in the order a request moves through them.
public enum RequestState: Int, Comparable, Sendable {
    /// Outgoing only: the handshake has not run yet, no safety code.
    case waiting
    /// The safety code is known; this member has not decided.
    case pending
    /// This member approved; the other member's approval is awaited.
    case approved

    public static func of(_ wire: String?) -> RequestState {
        switch wire {
        case "waiting": .waiting
        case "approved": .approved
        default: .pending
        }
    }

    public static func < (a: RequestState, b: RequestState) -> Bool { a.rawValue < b.rawValue }
}

/// How a connection request ended without a connection (§6.4).
public enum RequestEnd: Equatable, Sendable {
    /// This member declined (on this or another of their devices).
    case declined
    case expired
    /// The handshake was aborted, or an older vault let the request run out.
    case failed
    /// The other member declined (`connection.declined`, 0.10.5).
    case peerDeclined
    /// A decision found the request unknown to the vault (`not_found`): it ended another way, on another device or by
    /// its expiry, before this app learned how.
    case gone
}

/// The other member declined a connection request of this member's (0.10.5, §6.4): shown once, until the member
/// dismisses it. [outgoing]: this member accepted an invitation ("<name> declined your connection request"); else this
/// member invited ("<name> declined the connection"). [name] is the one the request showed (self-asserted), kept since
/// the request has left the list.
public struct PeerDecline: Equatable, Sendable, Codable {
    public var requestID: String
    public var name: String?
    public var outgoing: Bool
    public var at: Date

    public init(requestID: String, name: String?, outgoing: Bool, at: Date) {
        self.requestID = requestID
        self.name = name
        self.outgoing = outgoing
        self.at = at
    }
}
