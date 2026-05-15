import Foundation

// MARK: - Connection Audit Client

/// Wire-layer client for the **per-connection** audit trail.
///
/// The vault owns a `connection.audit.*` namespace that records one entry
/// per user-visible interaction (messages, calls, transfers, lifecycle,
/// system events) and exposes paginated list + FTS5-backed search.
/// Distinct from the global Security Audit Log (`audit.query`); that
/// surface has its own client and view in Features/Feed/AuditLogView.
///
/// Parity with Android `ConnectionAuditClient`. See
/// `vettid-dev/docs/CONNECTION-AUDIT-TRAIL-PLAN.md` for the trail design.
final class ConnectionAuditClient {

    private let ownerSpaceClient: OwnerSpaceClient
    private let defaultTimeout: TimeInterval = 15

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - List

    /// Time-ordered (DESC) paginated list of audit entries for a single
    /// connection. Optionally bracketed by `since`/`until` epoch-seconds
    /// and filtered to a set of `event_type` prefixes (e.g. `["call.",
    /// "message."]` for "calls and messages only").
    func list(
        connectionId: String,
        limit: Int = 100,
        cursor: AuditCursor? = nil,
        since: TimeInterval? = nil,
        until: TimeInterval? = nil,
        eventTypePrefixes: [String]? = nil
    ) async throws -> AuditListResult {
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "limit": AnyCodableValue(limit)
        ]
        if let cursor = cursor {
            payload["cursor_created_at"] = AnyCodableValue(Int(cursor.createdAt))
            payload["cursor_entry_id"] = AnyCodableValue(cursor.entryId)
        }
        if let since = since, since > 0 {
            payload["since_epoch"] = AnyCodableValue(Int(since))
        }
        if let until = until, until > 0 {
            payload["until_epoch"] = AnyCodableValue(Int(until))
        }
        if let prefixes = eventTypePrefixes, !prefixes.isEmpty {
            payload["event_types"] = AnyCodableValue(prefixes as [Any])
        }
        return try await send("connection.audit.list", payload: payload)
    }

    // MARK: - Search

    /// FTS5-backed search over the trail. The `query` is the user's typed
    /// text; the vault tokenizes and matches against `title` + `body`.
    func search(
        connectionId: String,
        query: String,
        limit: Int = 100,
        cursor: AuditCursor? = nil,
        eventTypePrefixes: [String]? = nil
    ) async throws -> AuditListResult {
        var payload: [String: AnyCodableValue] = [
            "connection_id": AnyCodableValue(connectionId),
            "query": AnyCodableValue(query),
            "limit": AnyCodableValue(limit)
        ]
        if let cursor = cursor {
            payload["cursor_created_at"] = AnyCodableValue(Int(cursor.createdAt))
            payload["cursor_entry_id"] = AnyCodableValue(cursor.entryId)
        }
        if let prefixes = eventTypePrefixes, !prefixes.isEmpty {
            payload["event_types"] = AnyCodableValue(prefixes as [Any])
        }
        return try await send("connection.audit.search", payload: payload)
    }

    // MARK: - Internals

    private func send(_ messageType: String, payload: [String: AnyCodableValue]) async throws -> AuditListResult {
        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            messageType,
            payload: payload,
            timeout: defaultTimeout
        )
        guard response.success, let result = response.result else {
            throw ConnectionAuditClientError.vaultError(response.error ?? "unknown")
        }
        return Self.parseResult(result)
    }

    private static func parseResult(_ result: [String: Any]) -> AuditListResult {
        let entriesRaw = (result["entries"] as? [[String: Any]]) ?? []
        let entries = entriesRaw.compactMap(AuditEntry.from(dict:))
        var nextCursor: AuditCursor?
        if let c = result["next_cursor"] as? [String: Any],
           let createdAt = c["created_at"] as? Double ?? (c["created_at"] as? Int).map(Double.init),
           let entryId = c["entry_id"] as? String {
            nextCursor = AuditCursor(createdAt: createdAt, entryId: entryId)
        }
        let total = result["total_estimate"] as? Int ?? entries.count
        return AuditListResult(entries: entries, nextCursor: nextCursor, totalEstimate: total)
    }
}

// MARK: - Data Models

/// One row in the per-connection audit trail. Event type strings match
/// the vault taxonomy: `message.sent` / `message.received` /
/// `call.voice.completed` / `call.video.missed` / `transfer.received` /
/// `system.guide.published` / `connection.lifecycle.activated` etc.
struct AuditEntry: Identifiable, Equatable {
    let entryId: String
    let connectionId: String
    let peerGuid: String?
    let eventType: String
    /// "sent" / "received" / nil for non-directional events.
    let direction: String?
    let title: String
    let body: String?
    /// Unix epoch seconds.
    let createdAt: TimeInterval
    /// Out-of-band references (e.g. `message_id`, `call_id`,
    /// `transfer_id`, `guide_id`). Used to deep-link from a row to the
    /// underlying object.
    let refs: [String: String]?
    let metadata: [String: String]?

    var id: String { entryId }
    var createdAtDate: Date { Date(timeIntervalSince1970: createdAt) }

    static func from(dict: [String: Any]) -> AuditEntry? {
        guard let entryId = dict["entry_id"] as? String,
              let connectionId = dict["connection_id"] as? String,
              let eventType = dict["event_type"] as? String,
              let title = dict["title"] as? String,
              let createdAt = dict["created_at"] as? Double
                ?? (dict["created_at"] as? Int).map(Double.init) else {
            return nil
        }
        return AuditEntry(
            entryId: entryId,
            connectionId: connectionId,
            peerGuid: dict["peer_guid"] as? String,
            eventType: eventType,
            direction: dict["direction"] as? String,
            title: title,
            body: dict["body"] as? String,
            createdAt: createdAt,
            refs: dict["refs"] as? [String: String],
            metadata: dict["metadata"] as? [String: String]
        )
    }
}

/// Opaque cursor for pagination. The vault returns one in `next_cursor`
/// when more entries are available; the client passes it back on the
/// next `list` / `search` call to continue from where it left off.
struct AuditCursor: Equatable {
    let createdAt: TimeInterval
    let entryId: String
}

struct AuditListResult {
    let entries: [AuditEntry]
    let nextCursor: AuditCursor?
    /// Best-effort estimate from the vault for empty-state messaging.
    let totalEstimate: Int
}

// MARK: - Time-range filter

/// Standard time ranges for the history filter chip set. Matches Android.
enum AuditTimeRange: String, CaseIterable, Identifiable {
    case all
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:        return "All time"
        case .today:      return "Today"
        case .last7Days:  return "Last 7 days"
        case .last30Days: return "Last 30 days"
        }
    }

    /// Lower bound for the query — unix epoch seconds, or nil for `.all`.
    var sinceEpoch: TimeInterval? {
        let now = Date()
        switch self {
        case .all:        return nil
        case .today:      return Calendar.current.startOfDay(for: now).timeIntervalSince1970
        case .last7Days:  return now.addingTimeInterval(-7  * 86_400).timeIntervalSince1970
        case .last30Days: return now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
        }
    }
}

// MARK: - Errors

enum ConnectionAuditClientError: LocalizedError {
    case vaultError(String)

    var errorDescription: String? {
        switch self {
        case .vaultError(let msg): return "Connection audit vault error: \(msg)"
        }
    }
}
