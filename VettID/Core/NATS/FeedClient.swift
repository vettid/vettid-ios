import Foundation

// MARK: - Feed Client

/// Client for unified feed/event system operations via NATS.
///
/// Uses OwnerSpaceClient.sendAndAwaitResponse() for proper request-response
/// correlation by event_id, avoiding race conditions.
///
/// Supports:
/// - Feed operations: list, get, action, read, archive, delete, sync
/// - Settings: get/update feed settings
/// - Audit: query, export
final class FeedClient {

    // MARK: - Properties

    private let ownerSpaceClient: OwnerSpaceClient
    private let defaultTimeout: TimeInterval = 10

    // MARK: - Initialization

    init(ownerSpaceClient: OwnerSpaceClient) {
        self.ownerSpaceClient = ownerSpaceClient
    }

    // MARK: - Feed Operations

    /// List feed items with optional filtering.
    /// - Parameters:
    ///   - status: Filter by status: "active", "read", "archived", or nil for all
    ///   - limit: Maximum number of items to return (default 50)
    ///   - offset: Pagination offset
    /// - Returns: Feed list response with events and total count
    func listFeed(status: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> FeedListResponse {
        var payload: [String: AnyCodableValue] = [
            "limit": AnyCodableValue(limit),
            "offset": AnyCodableValue(offset)
        ]

        if let status = status {
            payload["status"] = AnyCodableValue(status)
        }

        let response = try await sendAndAwait("feed.list", payload: payload)

        let events = parseEventArray(from: response, key: "events")
        let total = response.getInt("total") ?? events.count

        return FeedListResponse(events: events, total: total)
    }

    /// Get a single feed event by ID.
    /// - Parameter eventId: The event ID
    /// - Returns: The feed event
    func getEvent(eventId: String) async throws -> VaultFeedEvent {
        let response = try await sendAndAwait("feed.get", payload: [
            "event_id": AnyCodableValue(eventId)
        ])

        if let eventDict = response.getObject("event") {
            return parseEvent(from: eventDict)
        }

        // Fall back to parsing from result directly
        guard let result = response.result else {
            throw FeedClientError.invalidResponse("No event data in response")
        }

        return parseEvent(from: result)
    }

    /// Execute an action on a feed event (accept/decline/acknowledge).
    /// - Parameters:
    ///   - eventId: The event ID
    ///   - action: The action to take: "accept", "decline", "acknowledge", etc.
    ///   - data: Optional action-specific data
    func executeAction(eventId: String, action: String, data: [String: String]? = nil) async throws {
        var payload: [String: AnyCodableValue] = [
            "event_id": AnyCodableValue(eventId),
            "action": AnyCodableValue(action)
        ]

        if let data = data {
            let codableData = data.mapValues { AnyCodableValue($0) }
            payload["data"] = AnyCodableValue(codableData)
        }

        _ = try await sendAndAwait("feed.action", payload: payload)
    }

    /// Mark an event as read.
    /// - Parameter eventId: The event ID
    func markRead(eventId: String) async throws {
        _ = try await sendAndAwait("feed.read", payload: [
            "event_id": AnyCodableValue(eventId)
        ])
    }

    /// Mark multiple events as read.
    /// - Parameter eventIds: Array of event IDs to mark as read
    func markMultipleRead(eventIds: [String]) async throws {
        _ = try await sendAndAwait("feed.read", payload: [
            "event_ids": AnyCodableValue(eventIds)
        ])
    }

    /// Archive an event.
    /// - Parameter eventId: The event ID
    func archiveEvent(eventId: String) async throws {
        _ = try await sendAndAwait("feed.archive", payload: [
            "event_id": AnyCodableValue(eventId)
        ])
    }

    /// Delete (soft delete) an event.
    /// - Parameter eventId: The event ID
    func deleteEvent(eventId: String) async throws {
        _ = try await sendAndAwait("feed.delete", payload: [
            "event_id": AnyCodableValue(eventId)
        ])
    }

    /// Set the priority of a feed event.
    /// - Parameters:
    ///   - eventId: The event ID
    ///   - priority: Priority level: -1 (low), 0 (normal), 1 (high), 2 (urgent)
    func setEventPriority(eventId: String, priority: Int) async throws {
        _ = try await sendAndAwait("feed.set-priority", payload: [
            "event_id": AnyCodableValue(eventId),
            "priority": AnyCodableValue(priority)
        ])
    }

    // MARK: - Sync

    /// Sync events since a given sequence number.
    /// Used for incremental updates.
    /// - Parameters:
    ///   - sinceSequence: Get events with sequence > this value (0 for all)
    ///   - limit: Maximum events to return (default 100)
    /// - Returns: Sync response with events, latest sequence, and hasMore flag
    func sync(sinceSequence: Int64 = 0, limit: Int = 100) async throws -> FeedSyncResponse {
        let response = try await sendAndAwait("feed.sync", payload: [
            "since_sequence": AnyCodableValue(sinceSequence),
            "limit": AnyCodableValue(limit)
        ])

        let events = parseEventArray(from: response, key: "events")

        // Handle both Int and Int64 representations from JSON
        let latestSequence: Int64
        if let intVal = response.getInt("latest_sequence") {
            latestSequence = Int64(intVal)
        } else if let result = response.result, let numVal = result["latest_sequence"] {
            latestSequence = (numVal as? Int64) ?? Int64(numVal as? Int ?? 0)
        } else {
            latestSequence = 0
        }

        let hasMore = response.getBool("has_more") ?? false

        return FeedSyncResponse(events: events, latestSequence: latestSequence, hasMore: hasMore)
    }

    // MARK: - Settings

    /// Get feed settings.
    /// - Returns: Current feed settings
    func getSettings() async throws -> VaultFeedSettings {
        let response = try await sendAndAwait("feed.settings.get", payload: [:])

        let settingsDict: [String: Any]
        if let nested = response.getObject("settings") {
            settingsDict = nested
        } else {
            settingsDict = response.result ?? [:]
        }

        return parseSettings(from: settingsDict)
    }

    /// Update feed settings.
    /// - Parameter settings: The settings to update
    /// - Returns: Updated feed settings
    func updateSettings(_ settings: VaultFeedSettings) async throws -> VaultFeedSettings {
        let settingsPayload: [String: AnyCodableValue] = [
            "feed_retention_days": AnyCodableValue(settings.feedRetentionDays),
            "audit_retention_days": AnyCodableValue(settings.auditRetentionDays),
            "archive_behavior": AnyCodableValue(settings.archiveBehavior),
            "auto_archive_enabled": AnyCodableValue(settings.autoArchiveEnabled)
        ]

        let response = try await sendAndAwait("feed.settings.update", payload: [
            "settings": AnyCodableValue(settingsPayload)
        ])

        let settingsDict: [String: Any]
        if let nested = response.getObject("settings") {
            settingsDict = nested
        } else {
            settingsDict = response.result ?? [:]
        }

        return parseSettings(from: settingsDict)
    }

    // MARK: - Audit Operations

    /// Query audit log with filters.
    /// - Parameters:
    ///   - eventTypes: Filter by event types (e.g., ["call.incoming", "message.received"])
    ///   - startDate: Start date as epoch millis
    ///   - endDate: End date as epoch millis
    ///   - limit: Maximum results (default 100)
    /// - Returns: Audit query result with events and total count
    func queryAudit(
        eventTypes: [String]? = nil,
        startDate: TimeInterval? = nil,
        endDate: TimeInterval? = nil,
        limit: Int = 100
    ) async throws -> AuditQueryResult {
        var payload: [String: AnyCodableValue] = [
            "limit": AnyCodableValue(limit)
        ]

        if let eventTypes = eventTypes {
            payload["event_types"] = AnyCodableValue(eventTypes)
        }
        if let startDate = startDate {
            payload["start_date"] = AnyCodableValue(startDate)
        }
        if let endDate = endDate {
            payload["end_date"] = AnyCodableValue(endDate)
        }

        let response = try await sendAndAwait("audit.query", payload: payload)

        let events = parseEventArray(from: response, key: "events")
        let total = response.getInt("total") ?? events.count

        return AuditQueryResult(events: events, total: total)
    }

    /// Export audit events (max 1000).
    /// - Parameters:
    ///   - eventTypes: Filter by event types
    ///   - startDate: Start date as epoch millis
    ///   - endDate: End date as epoch millis
    /// - Returns: Export result with events and export timestamp
    func exportAudit(
        eventTypes: [String]? = nil,
        startDate: TimeInterval? = nil,
        endDate: TimeInterval? = nil
    ) async throws -> AuditExportResult {
        var payload: [String: AnyCodableValue] = [:]

        if let eventTypes = eventTypes {
            payload["event_types"] = AnyCodableValue(eventTypes)
        }
        if let startDate = startDate {
            payload["start_date"] = AnyCodableValue(startDate)
        }
        if let endDate = endDate {
            payload["end_date"] = AnyCodableValue(endDate)
        }

        let response = try await sendAndAwait("audit.export", payload: payload)

        let events = parseEventArray(from: response, key: "events")

        let exportedAt: TimeInterval
        if let intVal = response.getInt("exported_at") {
            exportedAt = TimeInterval(intVal)
        } else if let result = response.result, let numVal = result["exported_at"] {
            exportedAt = (numVal as? TimeInterval) ?? TimeInterval(numVal as? Int ?? 0)
        } else {
            exportedAt = Date().timeIntervalSince1970 * 1000
        }

        return AuditExportResult(events: events, exportedAt: exportedAt)
    }

    // MARK: - Private Helpers

    /// Send a request via OwnerSpaceClient and await the response.
    /// Throws on failure or timeout.
    private func sendAndAwait(
        _ messageType: String,
        payload: [String: AnyCodableValue],
        timeout: TimeInterval? = nil
    ) async throws -> VaultHandlerResponse {
        #if DEBUG
        print("[FeedClient] Sending \(messageType) request via OwnerSpaceClient")
        #endif

        let response = try await ownerSpaceClient.sendAndAwaitResponse(
            messageType,
            payload: payload,
            timeout: timeout ?? defaultTimeout
        )

        guard response.success else {
            let errorMsg = response.error ?? "Unknown error"
            #if DEBUG
            print("[FeedClient] \(messageType) error: \(errorMsg)")
            #endif
            throw FeedClientError.requestFailed(messageType, errorMsg)
        }

        return response
    }

    /// Parse an array of feed events from a vault response.
    private func parseEventArray(from response: VaultHandlerResponse, key: String) -> [VaultFeedEvent] {
        guard let eventsArray = response.getArray(key) else {
            return []
        }

        return eventsArray.map { parseEvent(from: $0) }
    }

    /// Parse a single VaultFeedEvent from a dictionary.
    private func parseEvent(from dict: [String: Any]) -> VaultFeedEvent {
        VaultFeedEvent(
            eventId: dict["event_id"] as? String ?? "",
            eventType: dict["event_type"] as? String ?? "",
            sourceType: dict["source_type"] as? String,
            sourceId: dict["source_id"] as? String,
            title: dict["title"] as? String ?? "",
            message: dict["message"] as? String,
            metadata: dict["metadata"] as? [String: String],
            feedStatus: dict["feed_status"] as? String ?? "active",
            actionType: dict["action_type"] as? String,
            priority: dict["priority"] as? Int ?? 0,
            createdAt: parseTimeInterval(dict["created_at"]),
            readAt: parseOptionalTimeInterval(dict["read_at"]),
            actionedAt: parseOptionalTimeInterval(dict["actioned_at"]),
            archivedAt: parseOptionalTimeInterval(dict["archived_at"]),
            expiresAt: parseOptionalTimeInterval(dict["expires_at"]),
            syncSequence: parseInt64(dict["sync_sequence"]),
            retentionClass: dict["retention_class"] as? String ?? "standard"
        )
    }

    /// Parse feed settings from a dictionary.
    private func parseSettings(from dict: [String: Any]) -> VaultFeedSettings {
        VaultFeedSettings(
            feedRetentionDays: dict["feed_retention_days"] as? Int ?? 30,
            auditRetentionDays: dict["audit_retention_days"] as? Int ?? 90,
            archiveBehavior: dict["archive_behavior"] as? String ?? "archive",
            autoArchiveEnabled: dict["auto_archive_enabled"] as? Bool ?? true,
            updatedAt: parseTimeInterval(dict["updated_at"])
        )
    }

    /// Parse a TimeInterval from various numeric representations.
    private func parseTimeInterval(_ value: Any?) -> TimeInterval {
        if let double = value as? Double { return double }
        if let int = value as? Int { return TimeInterval(int) }
        if let int64 = value as? Int64 { return TimeInterval(int64) }
        return 0
    }

    /// Parse an optional TimeInterval from various numeric representations.
    private func parseOptionalTimeInterval(_ value: Any?) -> TimeInterval? {
        guard let value = value, !(value is NSNull) else { return nil }
        if let double = value as? Double { return double }
        if let int = value as? Int { return TimeInterval(int) }
        if let int64 = value as? Int64 { return TimeInterval(int64) }
        return nil
    }

    /// Parse an Int64 from various numeric representations.
    private func parseInt64(_ value: Any?) -> Int64 {
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        if let double = value as? Double { return Int64(double) }
        return 0
    }
}

// MARK: - Feed Event Model

/// Unified feed event from the vault.
/// Uses "Vault" prefix to avoid collision with existing FeedEvent enum.
struct VaultFeedEvent: Codable, Identifiable {
    let eventId: String
    let eventType: String
    let sourceType: String?
    let sourceId: String?
    let title: String
    let message: String?
    let metadata: [String: String]?
    let feedStatus: String
    let actionType: String?
    let priority: Int
    let createdAt: TimeInterval   // epoch millis
    let readAt: TimeInterval?
    let actionedAt: TimeInterval?
    let archivedAt: TimeInterval?
    let expiresAt: TimeInterval?
    let syncSequence: Int64
    let retentionClass: String

    var id: String { eventId }

    /// Whether this event is unread
    var isUnread: Bool { feedStatus == "active" && readAt == nil }

    /// Whether this event requires user action
    var requiresAction: Bool { actionType != nil && !actionType!.isEmpty && actionedAt == nil }

    /// Priority level as enum
    var priorityLevel: EventPriorityLevel {
        switch priority {
        case -1: return .low
        case 0: return .normal
        case 1: return .high
        case 2: return .urgent
        default: return .normal
        }
    }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventType = "event_type"
        case sourceType = "source_type"
        case sourceId = "source_id"
        case title
        case message
        case metadata
        case feedStatus = "feed_status"
        case actionType = "action_type"
        case priority
        case createdAt = "created_at"
        case readAt = "read_at"
        case actionedAt = "actioned_at"
        case archivedAt = "archived_at"
        case expiresAt = "expires_at"
        case syncSequence = "sync_sequence"
        case retentionClass = "retention_class"
    }
}

// MARK: - Priority Level

enum EventPriorityLevel {
    case low
    case normal
    case high
    case urgent
}

// MARK: - Response Types

struct FeedListResponse {
    let events: [VaultFeedEvent]
    let total: Int
}

struct FeedSyncResponse {
    let events: [VaultFeedEvent]
    let latestSequence: Int64
    let hasMore: Bool
}

struct VaultFeedSettings: Codable {
    let feedRetentionDays: Int
    let auditRetentionDays: Int
    let archiveBehavior: String
    let autoArchiveEnabled: Bool
    let updatedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case feedRetentionDays = "feed_retention_days"
        case auditRetentionDays = "audit_retention_days"
        case archiveBehavior = "archive_behavior"
        case autoArchiveEnabled = "auto_archive_enabled"
        case updatedAt = "updated_at"
    }
}

struct AuditQueryResult {
    let events: [VaultFeedEvent]
    let total: Int
}

struct AuditExportResult {
    let events: [VaultFeedEvent]
    let exportedAt: TimeInterval
}

// MARK: - Errors

enum FeedClientError: LocalizedError {
    case requestFailed(String, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let operation, let reason):
            return "Feed \(operation) failed: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid feed response: \(reason)"
        }
    }
}
