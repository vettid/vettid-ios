import Foundation

// MARK: - Feed Display Item

/// Unified display item for the connection-centric feed.
/// Feed shows connection cards (primary) enriched by events, plus standalone events.
enum FeedDisplayItem: Identifiable {
    case connectionCard(ConnectionCardData)
    case eventItem(FeedEvent)

    var id: String {
        switch self {
        case .connectionCard(let card): return "conn-\(card.connectionId)"
        case .eventItem(let event): return "event-\(event.id)"
        }
    }

    var sortTimestamp: Date {
        switch self {
        case .connectionCard(let card): return card.sortTimestamp
        case .eventItem(let event): return event.timestamp
        }
    }
}

// MARK: - Connection Card Data

/// A connection-centric feed card showing peer info + latest activity.
struct ConnectionCardData: Identifiable {
    let connectionId: String
    let peerName: String
    let peerPhotoBase64: String?
    let peerEmail: String?
    let connectionStatus: String    // pending, active, revoked, rejected
    let direction: String           // inbound, outbound
    let needsReview: Bool
    let connectionType: String      // peer, agent, device
    let e2eReady: Bool
    let lastActivityPreview: String?
    let lastActivityType: String?
    let unreadCount: Int
    let sortTimestamp: Date
    let isUnread: Bool

    var id: String { connectionId }

    var isAgent: Bool { connectionType == "agent" }
    var isDevice: Bool { connectionType == "device" }
    var isPending: Bool { connectionStatus == "pending" }
    var isActive: Bool { connectionStatus == "active" }

    /// Build from a connection record with optional event enrichment.
    static func from(
        record: NatsConnectionRecord,
        lastActivityPreview: String? = nil,
        lastActivityType: String? = nil,
        unreadCount: Int = 0
    ) -> ConnectionCardData {
        let profile = record.peerProfile
        let displayName = profile?.displayName ?? record.label
        let needsReview = record.status == "pending" && record.direction == "inbound"

        return ConnectionCardData(
            connectionId: record.connectionId,
            peerName: displayName.isEmpty ? record.peerGuid : displayName,
            peerPhotoBase64: profile?.photo,
            peerEmail: profile?.email,
            connectionStatus: record.status,
            direction: record.direction,
            needsReview: needsReview,
            connectionType: record.connectionType,
            e2eReady: record.e2ePublicKey != nil,
            lastActivityPreview: lastActivityPreview,
            lastActivityType: lastActivityType,
            unreadCount: unreadCount,
            sortTimestamp: ISO8601DateFormatter().date(from: record.createdAt) ?? Date(),
            isUnread: unreadCount > 0 || needsReview
        )
    }
}

// MARK: - Event Type Categories

extension FeedEvent {
    /// Connection activity events that enrich connection cards (not shown standalone).
    static let connectionActivityTypes: Set<String> = [
        "MESSAGE_RECEIVED", "MESSAGE_SENT",
        "CALL_INITIATED", "CALL_RECEIVED", "CALL_MISSED", "CALL_COMPLETED",
        "TRANSFER_REQUEST",
        "AGENT_MESSAGE_RECEIVED", "AGENT_MESSAGE_SENT",
        "AGENT_SECRET_REQUEST", "AGENT_ACTION_REQUEST",
    ]

    /// Connection lifecycle events (handled by cards, not shown standalone).
    static let connectionLifecycleTypes: Set<String> = [
        "CONNECTION_REQUEST", "CONNECTION_ACCEPTED", "CONNECTION_DECLINED",
        "CONNECTION_REVOKED", "CONNECTION_ACTIVATED",
        "AGENT_CONNECTED", "AGENT_APPROVAL_REQUESTED",
    ]
}
