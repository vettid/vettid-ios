import Foundation

// MARK: - Grant Mode

/// How long an approved grant stays valid and whether the requester's
/// agents can re-pull values on the user's behalf.
enum GrantMode: String, Codable, CaseIterable, Identifiable {
    /// One value fetch, then the grant burns.
    case oneShot          = "ONE_SHOT"
    /// Multiple fetches until the grant expires.
    case renewable        = "RENEWABLE"
    /// The requester's authorized agents may also pull the value
    /// on their behalf without re-prompting the requester.
    case agentRenewable   = "AGENT_RENEWABLE"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneShot:        return "One-time access"
        case .renewable:      return "Renewable"
        case .agentRenewable: return "Agent-renewable"
        }
    }

    var explainer: String {
        switch self {
        case .oneShot:
            return "Peer can fetch the value once. The grant expires after the first read."
        case .renewable:
            return "Peer can re-fetch the value up to the max-uses limit until the grant expires."
        case .agentRenewable:
            return "Peer's authorized agents can also fetch the value on their behalf, within the grant's limits."
        }
    }
}

// MARK: - Grant Item Kind

/// What the grant covers — drives the icon, the deny-screen label, and
/// which vault namespace the grant_id resolves to.
enum GrantItemKind: String, Codable {
    /// A personal-data field (e.g. `contact.phone.mobile`).
    case data                  = "DATA"
    /// A minor secret's value.
    case minorSecret           = "MINOR_SECRET"
    /// A critical secret's VALUE (rare — almost always operations).
    case criticalSecretValue   = "CRITICAL_SECRET_VALUE"
    /// Permission to USE a critical secret in an operation, never
    /// receiving the value itself.
    case criticalSecretUse     = "CRITICAL_SECRET_USE"
    /// Identity-verify challenge.
    case identityVerify        = "IDENTITY_VERIFY"

    var displayName: String {
        switch self {
        case .data:                 return "Data"
        case .minorSecret:          return "Secret"
        case .criticalSecretValue:  return "Critical secret value"
        case .criticalSecretUse:    return "Critical secret operation"
        case .identityVerify:       return "Identity verification"
        }
    }

    var icon: String {
        switch self {
        case .data:                 return "folder.fill"
        case .minorSecret:          return "lock.fill"
        case .criticalSecretValue:  return "lock.shield"
        case .criticalSecretUse:    return "wand.and.stars"
        case .identityVerify:       return "checkmark.shield"
        }
    }
}

// MARK: - Grant Summary

/// One row in the inbound/outbound grant lists. Mirrors Android
/// `GrantSummary`. Vault is authoritative; this is a snapshot.
struct GrantSummary: Identifiable, Equatable {
    let grantId: String
    let connectionId: String
    /// Peer display name when we have it cached, else peer GUID — kept
    /// as a plain string so the row renders without an extra lookup.
    let peerLabel: String
    let kind: GrantItemKind
    let itemRef: String
    let itemLabel: String
    let mode: GrantMode
    /// "active" / "expired" / "revoked" / "exhausted".
    let status: String
    let createdAt: Date
    let expiresAt: Date?
    let maxUses: Int
    let usesRemaining: Int

    var id: String { grantId }

    static func from(dict: [String: Any]) -> GrantSummary? {
        guard let grantId = dict["grant_id"] as? String,
              let connectionId = dict["connection_id"] as? String,
              let itemRef = dict["item_ref"] as? String else {
            return nil
        }
        let kindRaw = (dict["item_kind"] as? String) ?? "DATA"
        let modeRaw = (dict["mode"] as? String) ?? "ONE_SHOT"
        let createdAt = (dict["created_at"] as? Double)
            ?? (dict["created_at"] as? Int).map(Double.init) ?? 0
        let expiresAt = (dict["expires_at"] as? Double)
            ?? (dict["expires_at"] as? Int).map(Double.init) ?? 0
        return GrantSummary(
            grantId: grantId,
            connectionId: connectionId,
            peerLabel: (dict["peer_label"] as? String) ?? (dict["peer_guid"] as? String) ?? "",
            kind: GrantItemKind(rawValue: kindRaw) ?? .data,
            itemRef: itemRef,
            itemLabel: (dict["item_label"] as? String) ?? itemRef,
            mode: GrantMode(rawValue: modeRaw) ?? .oneShot,
            status: (dict["status"] as? String) ?? "active",
            createdAt: createdAt > 0 ? Date(timeIntervalSince1970: createdAt) : Date(),
            expiresAt: expiresAt > 0 ? Date(timeIntervalSince1970: expiresAt) : nil,
            maxUses: (dict["max_uses"] as? Int) ?? 0,
            usesRemaining: (dict["uses_remaining"] as? Int) ?? 0
        )
    }
}

// MARK: - Pending Request Summary

/// Inbound request still awaiting an approve/deny decision. Owner-side
/// only; the user surfaces these in the GrantsView "Pending" tab and on
/// the connection card via `PendingRow.incomingGrantRequest`.
struct PendingRequestSummary: Identifiable, Equatable {
    let requestId: String
    let connectionId: String
    let peerLabel: String
    let kind: GrantItemKind
    let itemRef: String
    let itemLabel: String
    let requestedMode: GrantMode
    let requestedExpiresAt: Date?
    let requestedMaxUses: Int
    let reason: String
    let createdAt: Date

    var id: String { requestId }

    static func from(dict: [String: Any]) -> PendingRequestSummary? {
        guard let requestId = dict["request_id"] as? String,
              let connectionId = dict["connection_id"] as? String else {
            return nil
        }
        let kindRaw = (dict["item_kind"] as? String) ?? "DATA"
        let modeRaw = (dict["mode"] as? String) ?? "ONE_SHOT"
        let createdAt = (dict["created_at"] as? Double)
            ?? (dict["created_at"] as? Int).map(Double.init) ?? 0
        let expiresAt = (dict["requested_expires_at"] as? Double)
            ?? (dict["requested_expires_at"] as? Int).map(Double.init) ?? 0
        return PendingRequestSummary(
            requestId: requestId,
            connectionId: connectionId,
            peerLabel: (dict["peer_label"] as? String) ?? (dict["peer_guid"] as? String) ?? "",
            kind: GrantItemKind(rawValue: kindRaw) ?? .data,
            itemRef: (dict["item_ref"] as? String) ?? "",
            itemLabel: (dict["item_label"] as? String) ?? "",
            requestedMode: GrantMode(rawValue: modeRaw) ?? .oneShot,
            requestedExpiresAt: expiresAt > 0 ? Date(timeIntervalSince1970: expiresAt) : nil,
            requestedMaxUses: (dict["requested_max_uses"] as? Int) ?? 0,
            reason: (dict["reason"] as? String) ?? "",
            createdAt: createdAt > 0 ? Date(timeIntervalSince1970: createdAt) : Date()
        )
    }
}

// MARK: - Verify State Payload

/// Persistent per-connection identity-verify state. The vault publishes
/// this via `connection.get-verify-state` after every approve/deny.
/// The connection card's persistent verify-identity row (Phase 1.9)
/// reads from it.
struct VerifyStatePayload: Equatable {
    let connectionId: String
    /// Most recent inbound verify (peer challenged me). `ok == nil`
    /// means no challenge has landed yet.
    let lastInboundAt: Date?
    let lastInboundOk: Bool?
    let lastInboundReason: String?
    /// Most recent outbound verify (I challenged peer).
    let lastOutboundAt: Date?
    let lastOutboundOk: Bool?
    let lastOutboundReason: String?

    static func from(dict: [String: Any]) -> VerifyStatePayload? {
        guard let connectionId = dict["connection_id"] as? String else { return nil }
        func dateAt(_ key: String) -> Date? {
            guard let secs = (dict[key] as? Double)
                ?? (dict[key] as? Int).map(Double.init), secs > 0 else { return nil }
            return Date(timeIntervalSince1970: secs)
        }
        return VerifyStatePayload(
            connectionId: connectionId,
            lastInboundAt: dateAt("last_inbound_at"),
            lastInboundOk: dict["last_inbound_ok"] as? Bool,
            lastInboundReason: dict["last_inbound_reason"] as? String,
            lastOutboundAt: dateAt("last_outbound_at"),
            lastOutboundOk: dict["last_outbound_ok"] as? Bool,
            lastOutboundReason: dict["last_outbound_reason"] as? String
        )
    }
}
