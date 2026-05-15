import Foundation

// MARK: - Feed Display Item

/// Unified display item for the connection-centric feed.
///
/// In the connection-centric model (Phase 1.1, parity with Android
/// `FeedModels.kt`) the feed is *primarily* a list of connection cards.
/// Standalone events still exist for things that have no connection
/// (vault lifecycle, etc.) but cards are the primary surface — events
/// only enrich them as tappable `PendingRow`s rendered inside the card.
enum FeedDisplayItem: Identifiable {
    case connectionCard(ConnectionCardData)
    case eventItem(FeedEvent)
    /// Footer card surfacing the archived (declined / revoked / expired)
    /// connections in a flat count. Tap → `ArchivedConnectionsView`.
    case archivedConnections(count: Int)

    var id: String {
        switch self {
        case .connectionCard(let card): return "conn-\(card.connectionId)"
        case .eventItem(let event): return "event-\(event.id)"
        case .archivedConnections: return "archived-connections-footer"
        }
    }

    var sortTimestamp: Date {
        switch self {
        case .connectionCard(let card): return card.sortTimestamp
        case .eventItem(let event): return event.timestamp
        case .archivedConnections: return .distantPast   // always at the bottom
        }
    }
}

// MARK: - Pending Row (tappable notification rows on a card)

/// A tappable row rendered *inside* a connection card. Replaces the old
/// inline accept/decline/reply action buttons — every actionable thing on
/// a card is now a row that navigates to the relevant screen. Matches
/// Android `PendingRow`.
enum PendingRow: Identifiable, Equatable {
    /// Unread messages on this connection — tap → conversation.
    case unreadMessages(count: Int, preview: String?)
    /// Missed inbound call(s) — tap → call history (or call back if 1).
    case missedCall(count: Int, kind: CallKind, at: Date)
    /// Inbound pending connection that needs a review decision.
    case pendingReview
    /// Vault-side migration consent awaiting user action.
    case pendingMigration(version: String?)
    /// Guide row from the VettID system connection — system.guide.published.
    case guideUnread(guideId: String, title: String)
    /// Open vote on the VettID system card the user hasn't voted on yet.
    case proposalUnvoted(proposalId: String, title: String)
    /// Peer just published a fresh location share.
    case peerLocationShare(connectionId: String, at: Date)
    /// Inbound data-request grant awaiting approval (blocked on the Grants
    /// subsystem — Phase 3 — but the row type is defined so the card
    /// renderer doesn't have to grow when grants land).
    case incomingGrantRequest(requestId: String, kind: GrantKind)
    /// Outbound invitation the user sent that's still waiting on the
    /// other side. Tap → cancel (vault `connection.revoke`).
    case outboundInvitationPending(connectionId: String, expiresAt: Date?)
    /// Generic "last activity" line — kept as a row so cards never carry
    /// inline buttons that swap with action affordances.
    case lastActivity(text: String, direction: ActivityDirection, kind: ActivityKind, at: Date)

    var id: String {
        switch self {
        case .unreadMessages:                   return "unread-messages"
        case .missedCall(_, let kind, _):       return "missed-call-\(kind.rawValue)"
        case .pendingReview:                    return "pending-review"
        case .pendingMigration:                 return "pending-migration"
        case .guideUnread(let gid, _):          return "guide-\(gid)"
        case .proposalUnvoted(let pid, _):      return "proposal-\(pid)"
        case .peerLocationShare:                return "peer-location"
        case .incomingGrantRequest(let rid, _): return "grant-\(rid)"
        case .outboundInvitationPending(let cid, _): return "outbound-invitation-\(cid)"
        case .lastActivity(_, _, let kind, let at):
            return "last-activity-\(kind.rawValue)-\(Int(at.timeIntervalSince1970))"
        }
    }

    enum CallKind: String { case voice, video }
    enum ActivityDirection: String { case sent, received }
    enum ActivityKind: String {
        case message
        case voiceCall
        case videoCall
        case transfer
        case other
    }
    enum GrantKind: String {
        case data
        case criticalUse
        case verifyIdentity
    }
}

// MARK: - Connection Card Data

/// A connection-centric feed card showing peer info, latest activity,
/// pending action rows, and per-card BTC gating.
///
/// Mirrors Android `ConnectionCardData` (FeedModels.kt). Extends the
/// earlier iOS skeleton with the ~15 fields that drive the new visual
/// language: pending rows, direction-aware last-activity glyphs, BTC
/// affordances, and the VettID system-card flavor.
struct ConnectionCardData: Identifiable {

    // MARK: Identity

    let connectionId: String
    let peerName: String
    let peerPhotoBase64: String?
    let peerEmail: String?

    // MARK: Status

    let connectionStatus: String    // pending, active, revoked, declined, expired
    let direction: String           // inbound, outbound
    let needsReview: Bool
    let connectionType: String      // peer, agent, device, system
    let e2eReady: Bool

    /// True when WE sent an invitation that's still outstanding — drives
    /// the Cancel action on outbound pending cards.
    let hasOutstandingInvitation: Bool

    // MARK: Last activity (from vault `connection.list`)

    let lastActivityPreview: String?
    let lastActivityType: String?
    /// Direction arrow on the activity glyph (sent vs received).
    let lastActivityDirection: PendingRow.ActivityDirection?
    /// Subtype glyph (voice/video, transfer, message).
    let lastActivityKind: PendingRow.ActivityKind?
    let lastActivityAt: Date?

    let unreadCount: Int
    let missedCallCount: Int

    // MARK: Pending rows

    /// Tappable notification rows rendered inside the card. Drives all
    /// actions (review, reply, view missed call, vote, read guide, …).
    let pendingRows: [PendingRow]

    // MARK: BTC gating

    /// Peer has at least one wallet published in their profile — drives
    /// "Send" affordance on the card.
    let peerHasWallet: Bool
    /// User has a wallet — drives "Request" affordance.
    let localHasWallet: Bool
    /// Peer's first published BTC address, if any.
    let peerBtcAddress: String?

    // MARK: Presence (Phase 1.6)

    /// Last-seen timestamp from the presence aggregator. `nil` means
    /// "no recent heartbeat" / show no ring. The system card never
    /// has presence.
    let presenceLastSeen: Date?

    // MARK: Sort

    let sortTimestamp: Date
    let isUnread: Bool

    var id: String { connectionId }

    // MARK: Convenience flags

    var isAgent: Bool   { connectionType == "agent" }
    var isDevice: Bool  { connectionType == "device" }
    var isSystem: Bool  { connectionType == "system" }
    var isPending: Bool { connectionStatus == "pending" }
    var isActive: Bool  { connectionStatus == "active" }
    var isTerminal: Bool {
        Self.terminalStatuses.contains(connectionStatus)
    }

    /// Connection statuses that drop out of the live feed and into the
    /// archived footer (Phase 1.7). Matches Android `TERMINAL_HIDDEN_STATUSES`.
    static let terminalStatuses: Set<String> = ["revoked", "declined", "rejected", "expired"]

    // MARK: Builders

    /// Build from a raw `connection.list` record. Optional enrichment
    /// args layer on event-derived activity + pending rows; defaults
    /// produce a still-functional bare card.
    static func from(
        record: NatsConnectionRecord,
        lastActivityPreview: String? = nil,
        lastActivityType: String? = nil,
        lastActivityDirection: PendingRow.ActivityDirection? = nil,
        lastActivityKind: PendingRow.ActivityKind? = nil,
        lastActivityAt: Date? = nil,
        unreadCount: Int = 0,
        missedCallCount: Int = 0,
        pendingRows: [PendingRow] = [],
        peerHasWallet: Bool = false,
        localHasWallet: Bool = false,
        peerBtcAddress: String? = nil,
        presenceLastSeen: Date? = nil
    ) -> ConnectionCardData {
        let profile = record.peerProfile
        let displayName = profile?.displayName ?? record.label
        let needsReview = record.status == "pending" && record.direction == "inbound"
        let hasOutstanding = record.status == "pending" && record.direction == "outbound"

        let createdAt = ISO8601DateFormatter().date(from: record.createdAt) ?? Date()
        let sort = lastActivityAt ?? createdAt

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
            hasOutstandingInvitation: hasOutstanding,
            lastActivityPreview: lastActivityPreview,
            lastActivityType: lastActivityType,
            lastActivityDirection: lastActivityDirection,
            lastActivityKind: lastActivityKind,
            lastActivityAt: lastActivityAt,
            unreadCount: unreadCount,
            missedCallCount: missedCallCount,
            pendingRows: pendingRows,
            peerHasWallet: peerHasWallet,
            localHasWallet: localHasWallet,
            peerBtcAddress: peerBtcAddress,
            presenceLastSeen: presenceLastSeen,
            sortTimestamp: sort,
            isUnread: unreadCount > 0 || needsReview || !pendingRows.isEmpty
        )
    }

    /// Synthesize the VettID system connection card. There's exactly
    /// one of these in the feed; it owns Messages / Votes / Guides
    /// affordances and routes to vault-mediated screens.
    static func systemCard(
        guidesUnread: [(guideId: String, title: String)] = [],
        votesOpen: [(proposalId: String, title: String)] = [],
        vaultMessagesUnread: Int = 0,
        latestAt: Date = Date()
    ) -> ConnectionCardData {
        var rows: [PendingRow] = []
        rows.append(contentsOf: guidesUnread.map {
            PendingRow.guideUnread(guideId: $0.guideId, title: $0.title)
        })
        rows.append(contentsOf: votesOpen.map {
            PendingRow.proposalUnvoted(proposalId: $0.proposalId, title: $0.title)
        })
        return ConnectionCardData(
            connectionId: "system-vettid",
            peerName: "VettID",
            peerPhotoBase64: nil,
            peerEmail: nil,
            connectionStatus: "active",
            direction: "system",
            needsReview: false,
            connectionType: "system",
            e2eReady: true,
            hasOutstandingInvitation: false,
            lastActivityPreview: nil,
            lastActivityType: nil,
            lastActivityDirection: nil,
            lastActivityKind: nil,
            lastActivityAt: latestAt,
            unreadCount: vaultMessagesUnread,
            missedCallCount: 0,
            pendingRows: rows,
            peerHasWallet: false,
            localHasWallet: false,
            peerBtcAddress: nil,
            presenceLastSeen: nil,
            sortTimestamp: latestAt,
            isUnread: !rows.isEmpty || vaultMessagesUnread > 0
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
