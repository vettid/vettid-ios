import Foundation

// MARK: - Shared Item (peer-catalog row)

/// One row in the peer-catalog list — sourced from the peer's published
/// data_catalog + secret_catalog (which `BusinessCardView` already
/// renders inline; this surface is the focused full-screen view).
/// `status` reflects the local user's outstanding capability requests
/// for the item.
///
/// Mirrors Android `SharedItem`.
struct SharedItem: Identifiable, Equatable, Hashable {
    enum Kind: String, Codable { case data, secret, wallet }

    /// Stable key: `"<kind>:<id>"` matching the vault's store. The
    /// peer-side vault uses this for grant resolution.
    let key: String
    let displayName: String
    let category: String
    let kind: Kind
    let status: SharedItemStatus
    /// Last request id we sent for this item — used to retry / open
    /// the detail. Nil when no request has been made.
    let requestId: String?
    /// Cataloged-for-use critical secrets: peer can ASK the owner to
    /// perform an operation but never receives the value. The UI swaps
    /// "Request" for "Ask to use" when this is true. Inferred from the
    /// catalog visibility tier being `USE_ONLY`.
    let useOnly: Bool

    var id: String { key }
}

enum SharedItemStatus: String, Codable {
    case available     // never asked
    case pending       // asked; awaiting peer response
    case approved      // peer approved
    case denied        // peer denied
    case expired       // capability expired

    var displayLabel: String {
        switch self {
        case .available: return "Available"
        case .pending:   return "Requested"
        case .approved:  return "Approved"
        case .denied:    return "Denied"
        case .expired:   return "Expired"
        }
    }
}

// MARK: - Share Policy Row (my-sharing editor)

/// One row in the my-sharing editor — represents a single decision the
/// local user has made about what THIS peer can request. Mirrors
/// Android `SharePolicyRow`.
struct SharePolicyRow: Identifiable, Equatable, Hashable {

    enum Tier: String, Codable, CaseIterable, Identifiable {
        case required, optional, onDemand = "on_demand", consent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .required: return "Required"
            case .optional: return "Optional"
            case .onDemand: return "On demand"
            case .consent:  return "Per-request consent"
            }
        }
    }

    enum Retention: String, Codable, CaseIterable, Identifiable {
        case session, timeLimited = "time_limited", untilRevoked = "until_revoked"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .session:      return "Session-only"
            case .timeLimited:  return "Time-limited"
            case .untilRevoked: return "Until revoked"
            }
        }
    }

    /// Stable key: `"<kind>:<id>"` matching the vault store.
    let key: String
    let displayName: String
    let category: String
    var allowed: Bool
    var tier: Tier
    var retention: Retention
    /// 0 = unlimited
    var rateLimitPerHour: Int
    /// nil = never (Android uses 0 as the sentinel; we use Date? for
    /// type safety).
    var expiresAt: Date?

    var id: String { key }
}
