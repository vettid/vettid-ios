import Foundation
import VettIDCrypto

/// A field of the member's item as a grant request names it (VAULT-MESSAGING 0.21.0 §10.12 `labels`): its id, label and
/// kind, never its value.
public struct GrantFieldLabel: Equatable, Sendable, Codable {
    public var fieldID: String
    public var label: String
    public var kind: String
}

/// An entry of a grant request (§10.12): an item the asker names (`kind` `item`), or a category the member answers with
/// one of their items. [label] is the asker's own words. For an available `item` entry the member's vault adds the
/// item's current [name], [category] and the [labels] of the fields it would grant (0.21.0). Mirrors vettid-android
/// `GrantEntry`.
public struct GrantEntry: Equatable, Sendable {
    public var kind: String
    public var ref: String
    public var label: String?
    public var available: Bool
    public var name: String?
    public var category: String?
    public var labels: [GrantFieldLabel]?
}

/// The member's answer to a grant request (§10.12): [items] the entry indexes granted; [answers] the member's item for
/// a category entry (index → item id); [uses] (1–100) and [expiresInSeconds] (60–31,536,000) replace the request's when
/// set. Mirrors vettid-android `GrantDecision`.
public struct GrantDecision: Equatable, Sendable {
    public var items: [Int]
    public var answers: [Int: String]
    public var uses: Int?
    public var expiresInSeconds: Int?

    public init(items: [Int], answers: [Int: String] = [:], uses: Int? = nil, expiresInSeconds: Int? = nil) {
        self.items = items
        self.answers = answers
        self.uses = uses
        self.expiresInSeconds = expiresInSeconds
    }
}

/// An item waiting for a share decision (§10.12 `share.pending`). Since 0.23.0: [askRuleID] names the `ask` rule of the
/// same subject that holds it in an `auto` rule, and [shared] says another rule of the subject already shares it, which
/// a decline stops. Mirrors vettid-android `ShareItem`.
public struct ShareItem: Equatable, Sendable {
    public var itemID: String
    public var name: String
    public var category: String
    public var sensitivity: String
    public var askRuleID: String?
    public var shared: Bool
}

/// `connection.authenticate.pending` (§10.4): sign a connection's challenge with the credential key.
public struct AuthenticationRequest: Equatable, Sendable {
    public var requestID: String
    public var connectionID: String
    public var context: String?
    public var receivedAt: Date
    public var exp: Date?
}

/// `grant.pending`, or an entry of `grant.list`'s `pending` (§10.12): a connection asks to read items.
public struct GrantRequest: Equatable, Sendable {
    public var requestID: String
    public var connectionID: String
    public var entries: [GrantEntry]
    public var uses: Int?
    public var expiresIn: Int64?
    public var reason: String?
    public var receivedAt: Date
    public var exp: Date?

    /// The entries an approval grants now (named items that exist); category entries need an answer.
    public var grantable: [Int] { entries.indices.filter { entries[$0].kind == "item" && entries[$0].available } }
}

/// `critical-secret-use.pending`, or an entry of `critical-secret-use.list`'s `incoming` (no [payload] until
/// `critical-secret-use.get`), §10.13: one use of a critical item, consented with the credential password.
public struct CriticalUse: Equatable, Sendable {
    /// The field kinds that can hold an Ed25519 seed for a use (0.21.0 §10.13 Suitability).
    public static let suitableKinds: Set<String> = ["password", "text", "multiline"]

    public var requestID: String
    public var connectionID: String
    public var itemName: String
    public var fieldLabel: String
    public var operation: String
    /// Standard base64, as the vault sent it; "" until fetched.
    public var payload: String
    /// Standard base64 of SHA-256(payload), as the vault sent it.
    public var payloadSha256: String
    public var context: String?
    public var receivedAt: Date
    public var exp: Date?
    /// The field's kind (0.21.0), as the vault recorded it; nil from an older vault.
    public var kind: String?

    /// Whether the field can hold the seed a use needs; nil when the vault did not say. One that cannot is only denied.
    public var suitable: Bool? { kind.map { Self.suitableKinds.contains($0) } }

    /// The payload is here and SHA-256(payload) equals [payloadSha256] (§10.13): only then is it shown and the approval
    /// offered.
    public var payloadVerified: Bool {
        guard !payload.isEmpty, let sha = Self.sha256(payload), let want = try? Base64s.decodeStd(payloadSha256, 32) else { return false }
        return Bytes.constantTimeEquals(sha, want)
    }

    /// SHA-256 of a standard-base64 payload; nil when it is not base64.
    static func sha256(_ payloadB64: String) -> [UInt8]? {
        (try? Base64s.decodeStd(payloadB64)).map { Bytes.sha256($0) }
    }
}

/// `share.pending` (§10.12): items one of the member's share rules asks about. The rule's tags and the subject's other
/// rules come from `share.rule.list` with the share rules (IOS-PLAN §8 I3.2).
public struct ShareDecision: Equatable, Sendable {
    public var ruleID: String
    public var subjectConnectionID: String?
    public var subjectAgentID: String?
    public var items: [ShareItem]
    public var reason: String?
    public var receivedAt: Date
}

/// A desktop's or an agent's request (`approval.pending`, `device.session.pending`, §6.8): the app pairs no desktops or
/// agents yet, so it can only be declined.
public struct DeviceRequest: Equatable, Sendable {
    /// The event type, `approval.pending` or `device.session.pending`.
    public var type: String
    public var id: String
    public var deviceName: String?
    public var role: String?
    public var requestType: String?
    public var receivedAt: Date
    public var exp: Date?
}

/// Something that waits for the member's decision (ANDROID-PLAN §4 Approvals). [key] is stable and unique across the
/// kinds (``FeedAsks`` maps it to the feed item); [connectionName] is resolved from the connection list where the request
/// names a connection. The connection requests are those of ``ConnectionRequestsRepository`` (IOS-PLAN §8 I2.3: they
/// move to Approvals, as in vettid-android). Mirrors vettid-android `Approval` (renamed: VettIDAltChan has an `Approval`, the release approval).
public enum PendingApproval: Equatable, Sendable {
    case connection(PendingConnection)
    case authentication(AuthenticationRequest)
    case grant(GrantRequest)
    case critical(CriticalUse)
    case share(ShareDecision)
    case device(DeviceRequest)

    public var key: String {
        switch self {
        case .connection(let r): r.key
        case .authentication(let a): "auth:\(a.requestID)"
        case .grant(let g): "grant:\(g.requestID)"
        case .critical(let c): "critical:\(c.requestID)"
        case .share(let s): "share:\(s.ruleID)"
        case .device(let d): "device:\(d.type):\(d.id)"
        }
    }

    public var receivedAt: Date {
        switch self {
        case .connection(let r): r.receivedAt
        case .authentication(let a): a.receivedAt
        case .grant(let g): g.receivedAt
        case .critical(let c): c.receivedAt
        case .share(let s): s.receivedAt
        case .device(let d): d.receivedAt
        }
    }

    public var exp: Date? {
        switch self {
        case .connection(let r): r.exp
        case .authentication(let a): a.exp
        case .grant(let g): g.exp
        case .critical(let c): c.exp
        case .share: nil
        case .device(let d): d.exp
        }
    }

    /// The connection the request comes from (a share decision's subject), when it names one.
    public var connectionID: String? {
        switch self {
        case .connection: nil
        case .authentication(let a): a.connectionID
        case .grant(let g): g.connectionID
        case .critical(let c): c.connectionID
        case .share(let s): s.subjectConnectionID
        case .device: nil
        }
    }

    /// Whether the member has something to decide: a connection request whose safety code is known and that this member
    /// has not approved yet; every other kind until it is decided.
    public var needsDecision: Bool {
        if case .connection(let r) = self { return r.needsDecision }
        return true
    }
}
