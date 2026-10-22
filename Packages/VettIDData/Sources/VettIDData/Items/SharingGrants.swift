import Foundation
import VettIDCrypto
import VettIDVault

/// Which way a grant goes (§10.12). Mirrors vettid-android `GrantDirection`.
public enum GrantDirection: Sendable {
    case given
    case received
}

/// A grant (§10.12): one connection may read one item (or some of its fields). Mirrors vettid-android `GrantView`.
public struct GrantView: Equatable, Sendable, Identifiable {
    public static let stateActive = "active"

    public var grantID: String
    public var connectionID: String
    public var direction: GrantDirection
    public var itemRef: String
    public var name: String
    public var category: String
    public var fields: [String]?
    public var label: String?
    public var ruleID: String?
    public var uses: Int?
    public var used: Int
    public var expiresAt: Date?
    /// `active`, `used`, `expired` or `revoked`.
    public var state: String
    public var createdAt: Date?
    /// A received grant's field labels, as the connection's vault described them (`grant.list`, VAULT-MESSAGING 0.21.0
    /// §10.12; not refreshed): what it holds before it is fetched. Empty for a given grant and from an older vault.
    public var labels: [GrantFieldLabel]
    /// The rate limits of the rule that gave it (`limits`, 0.23.0 §10.12): the rule's current ones for a given grant, as of
    /// issue for a received one; nil when not limited.
    public var perHour: Int?
    public var perDay: Int?

    public init(
        grantID: String, connectionID: String, direction: GrantDirection, itemRef: String, name: String, category: String,
        fields: [String]? = nil, label: String? = nil, ruleID: String? = nil, uses: Int? = nil, used: Int = 0, expiresAt: Date? = nil,
        state: String = GrantView.stateActive, createdAt: Date? = nil, labels: [GrantFieldLabel] = [], perHour: Int? = nil,
        perDay: Int? = nil
    ) {
        self.grantID = grantID
        self.connectionID = connectionID
        self.direction = direction
        self.itemRef = itemRef
        self.name = name
        self.category = category
        self.fields = fields
        self.label = label
        self.ruleID = ruleID
        self.uses = uses
        self.used = used
        self.expiresAt = expiresAt
        self.state = state
        self.createdAt = createdAt
        self.labels = labels
        self.perHour = perHour
        self.perDay = perDay
    }

    public var id: String { grantID }
    public var active: Bool { state == Self.stateActive }

    /// Uses left of a counted grant; nil when not counted.
    public var usesLeft: Int? { uses.map { max(0, $0 - used) } }
}

/// One entry of a request this vault made (§10.12 `grant.request`, as sent): an `item` or a `category` [ref], the asker's
/// [label]. Mirrors vettid-android `GrantAskEntry`.
public struct GrantAskEntry: Equatable, Sendable {
    public var kind: String
    public var ref: String
    public var label: String?

    public init(kind: String, ref: String, label: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.label = label
    }
}

/// A request this vault made of a connection (`grant.list`'s `requested`, §10.12 as 0.21.0 pins it): its [entries] exactly
/// as sent, and [state] `pending`, `granted` (some entries granted: they arrive as received grants) or `denied` (denied, or
/// not decided within 7 days). Mirrors vettid-android `GrantAsk`.
public struct GrantAsk: Equatable, Sendable, Identifiable {
    public var requestID: String
    public var connectionID: String
    public var entries: [GrantAskEntry]
    public var state: String

    public init(requestID: String, connectionID: String, entries: [GrantAskEntry], state: String) {
        self.requestID = requestID
        self.connectionID = connectionID
        self.entries = entries
        self.state = state
    }

    public var id: String { requestID }
}

/// Grants given and received, and the requests this vault made (`grant.list`). Mirrors vettid-android `GrantLists`.
public struct GrantLists: Equatable, Sendable {
    public var given: [GrantView]
    public var received: [GrantView]
    public var requested: [GrantAsk]

    public init(given: [GrantView], received: [GrantView], requested: [GrantAsk] = []) {
        self.given = given
        self.received = received
        self.requested = requested
    }
}

/// What a connection shared with the member, as fetched (§10.12): read-only, the connection's own data. Never printed or
/// reflected. Mirrors vettid-android `SharedContent`.
public struct SharedContent: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var itemID: String
    public var name: String
    public var category: String
    public var fields: [ItemFieldView]
    public var notes: String?
    public var usesLeft: Int64?

    public init(itemID: String, name: String, category: String, fields: [ItemFieldView], notes: String?, usesLeft: Int64?) {
        self.itemID = itemID
        self.name = name
        self.category = category
        self.fields = fields
        self.notes = notes
        self.usesLeft = usesLeft
    }

    public var description: String { "SharedContent(\(itemID))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A fetch's outcome: the content, or the connection's vault's refusal (`revoked`, `expired`, `exhausted`, `unavailable`,
/// `not_found`; 0.23.0 `rate_limited` with ``refused(_:retryAfter:)``'s whole seconds). Mirrors vettid-android `FetchOutcome`.
public enum FetchOutcome: Equatable, Sendable {
    case shared(SharedContent)
    case refused(String, retryAfter: Int64? = nil)

    public static let rateLimited = "rate_limited"
}
