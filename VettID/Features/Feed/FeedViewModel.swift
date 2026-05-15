import Foundation
import SwiftUI

// MARK: - Feed View Model

/// Connection-centric feed (Phase 1.1).
///
/// The list is driven by `connection.list` from the vault; events only
/// **enrich** cards (as tappable `PendingRow`s rendered inside the card).
/// There is no flat "list of events" tab anymore — that's the legacy
/// model and was removed when Android collapsed nav to two destinations.
///
/// What's still here:
///   - `state` is the loading/empty/loaded/error machine the view binds to.
///   - `displayItems` is the connection-centric list (cards + standalone
///     events + an optional archived-connections footer).
///   - `searchQuery` filters cards by peer name / last-activity preview.
///
/// What's gone:
///   - The All/Messages/Connections/Auth/Activity/Agents/Devices filter
///     chips. Those concerns are now expressed by which cards have
///     `PendingRow`s and what kinds.
///   - Inline accept/decline buttons on the row. Tapping `PendingRow`s
///     navigates to the relevant decision screen; the actions are still
///     on the ViewModel (`acceptConnection`, `declineConnection`,
///     `approveAuth`, `denyAuth`) for the screens that need them.
@MainActor
final class FeedViewModel: ObservableObject {

    enum State: Equatable {
        case loading
        case empty
        case loaded
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.empty, .empty), (.loaded, .loaded): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var state: State = .loading
    @Published var displayItems: [FeedDisplayItem] = []
    @Published var isProcessingAction = false
    @Published var actionError: String?
    @Published var searchQuery = ""

    // Backing data — re-built into `displayItems` after every load.
    private var allEvents: [FeedEvent] = []
    private var connectionRecords: [NatsConnectionRecord] = []
    /// Snapshot of online connections fetched from `PresenceAggregator`
    /// once per build. Cleared and re-fetched at the start of each
    /// `rebuildDisplayItems`; we don't subscribe to presence here because
    /// `loadEvents()` already re-runs on every tick worth caring about
    /// (refresh, resume, action result). When live presence reactivity
    /// is needed, the FeedView can observe the aggregator directly.
    private var presenceSnapshot: [String: Date] = [:]

    private var vaultResponseHandler: VaultResponseHandler?
    private var feedClient: FeedClient?
    var connectionsClient: ConnectionsClient?
    private var refreshTimer: Timer?

    // MARK: - Configuration

    func configure(with vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    func configure(feedClient: FeedClient) {
        self.feedClient = feedClient
    }

    // MARK: - Load

    func loadEvents() async {
        state = .loading

        // Load connections (primary source) and events (enrichment) in parallel.
        async let connectionsTask: () = loadConnections()
        async let eventsTask: () = loadEventsFromVault()
        _ = await (connectionsTask, eventsTask)

        // Refresh the presence snapshot used by the build.
        presenceSnapshot = await PresenceAggregator.shared.snapshot()

        rebuildDisplayItems()
    }

    private func loadConnections() async {
        guard let client = connectionsClient else { return }
        do {
            let result = try await client.list(status: nil)
            connectionRecords = result.items
        } catch {
            #if DEBUG
            print("[FeedViewModel] Failed to load connections: \(error)")
            #endif
        }
    }

    private func loadEventsFromVault() async {
        if feedClient != nil {
            await loadFromVault()
        } else {
            try? await Task.sleep(nanoseconds: 500_000_000)
            allEvents = FeedEvent.mockFeed()
        }
    }

    // MARK: - Build Display Items

    /// Fold connections + events into the connection-centric list:
    ///   - hide terminal-status connections from the live list (they live
    ///     behind the archived-connections footer instead);
    ///   - for each live connection, enrich the card with events targeting
    ///     it (unread count, last-activity preview / direction / kind);
    ///   - emit one `archivedConnections` footer if any were hidden;
    ///   - keep standalone events (vault lifecycle, etc.) above-the-fold.
    ///
    /// Always called on the main actor.
    private func rebuildDisplayItems() {
        var items: [FeedDisplayItem] = []
        var archivedCount = 0

        // VettID system connection card — synthesized, not from
        // `connection.list`. Sits at the top of the feed and owns
        // Guides / Votes / VaultMessages routing (Phase 1.2).
        items.append(.connectionCard(buildSystemCard()))

        // Snapshot presence once per rebuild so all cards see a coherent
        // map. Re-builds run on every refresh and on event arrival, so a
        // stale snapshot would only persist for that one tick.
        let presenceMap = presenceSnapshot

        for record in connectionRecords {
            if ConnectionCardData.terminalStatuses.contains(record.status) {
                archivedCount += 1
                continue
            }
            items.append(.connectionCard(buildCard(for: record, presence: presenceMap[record.connectionId])))
        }

        // Standalone events that don't belong to any card.
        for event in allEvents {
            if shouldHideStandalone(event) { continue }
            items.append(.eventItem(event))
        }

        // Archived footer at the bottom of the list.
        if archivedCount > 0 {
            items.append(.archivedConnections(count: archivedCount))
        }

        // Sort: connection cards by their sortTimestamp; events by their
        // own timestamp; archived footer always last (sortTimestamp =
        // distantPast handles it).
        items.sort { lhs, rhs in
            if case .archivedConnections = lhs { return false }
            if case .archivedConnections = rhs { return true }
            return lhs.sortTimestamp > rhs.sortTimestamp
        }

        // Apply search filter to the materialized list.
        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            items = items.filter { item in
                switch item {
                case .connectionCard(let c):
                    return c.peerName.lowercased().contains(q) ||
                           (c.lastActivityPreview?.lowercased().contains(q) ?? false)
                case .eventItem(let e):
                    return Self.eventMatchesQuery(e, q)
                case .archivedConnections:
                    return false
                }
            }
        }

        displayItems = items
        state = items.isEmpty ? .empty : .loaded
    }

    /// Synthesize the VettID system card. Pulls unread guides from
    /// `GuideReadTracker` and open-unvoted proposals from the injected
    /// digest. Lives at the top of the feed and routes Guides / Votes /
    /// VaultMessages.
    private func buildSystemCard() -> ConnectionCardData {
        let unread = GuideReadTracker.shared.unreadGuides().map {
            (guideId: $0.rawValue, title: $0.title)
        }
        let votes = unvotedOpenProposals.map {
            (proposalId: $0.id, title: $0.title)
        }
        return ConnectionCardData.systemCard(
            guidesUnread: unread,
            votesOpen: votes,
            vaultMessagesUnread: vaultMessagesUnreadCount,
            latestAt: Date()
        )
    }

    /// Open proposals the user hasn't voted on, supplied externally
    /// (e.g. by the screen wrapper). Defaults to empty until wired.
    var unvotedOpenProposals: [(id: String, title: String)] = []

    /// Unread count for deferred vault-update messages (the
    /// VaultMessagesView surface — Phase 1.2). Defaults to zero until
    /// the underlying queue exists.
    var vaultMessagesUnreadCount: Int = 0

    /// Build a single connection card by joining the record with events
    /// targeting it. Synthesizes `PendingRow`s from both event state and
    /// the connection's lifecycle status. `presence` is the last-seen
    /// timestamp from `PresenceAggregator`, or nil when the peer hasn't
    /// sent a heartbeat within the timeout (~90s).
    private func buildCard(for record: NatsConnectionRecord, presence: Date? = nil) -> ConnectionCardData {
        // Events targeting this connection (any kind).
        let connEvents = allEvents.filter { event in
            switch event {
            case .message(let e):         return e.connectionId == record.connectionId
            case .transferRequest(let e): return e.connectionId == record.connectionId
            default:                       return false
            }
        }

        // Latest activity drives the preview and the sortTimestamp.
        let latest = connEvents.sorted { $0.timestamp > $1.timestamp }.first
        let preview: String?
        let kind: PendingRow.ActivityKind?
        let direction: PendingRow.ActivityDirection?
        let activityAt: Date?
        switch latest {
        case .message(let e)?:
            preview = e.preview
            kind = .message
            direction = .received    // FeedEvent.message has no direction; assume received
            activityAt = e.timestamp
        case .transferRequest(let e)?:
            preview = "Payment request: \(String(format: "%.8f", e.amountBtc)) BTC"
            kind = .transfer
            direction = .received
            activityAt = e.timestamp
        default:
            preview = nil
            kind = nil
            direction = nil
            activityAt = nil
        }

        // Pending rows — order matters; review/migration float to the top.
        var rows: [PendingRow] = []
        if record.status == "pending" && record.direction == "inbound" {
            rows.append(.pendingReview)
        }
        let unread = connEvents.filter { !$0.isRead }.count
        if unread > 0 {
            rows.append(.unreadMessages(count: unread, preview: preview))
        }
        // (missedCall / peerLocationShare / incomingGrantRequest synthesis
        // happens once the corresponding event types arrive on the wire
        // — Phases 1.4 / 1.6 / 3.)

        return ConnectionCardData.from(
            record: record,
            lastActivityPreview: preview,
            lastActivityType: kind?.rawValue,
            lastActivityDirection: direction,
            lastActivityKind: kind,
            lastActivityAt: activityAt,
            unreadCount: unread,
            pendingRows: rows,
            presenceLastSeen: presence
        )
    }

    private func shouldHideStandalone(_ event: FeedEvent) -> Bool {
        // Connection-attached events are rendered as PendingRows inside
        // the card; suppress them as standalone items.
        let type: String
        switch event {
        case .message:           type = "MESSAGE_RECEIVED"
        case .connectionRequest: type = "CONNECTION_REQUEST"
        case .authRequest:       type = "auth.request"
        case .vaultActivity:     type = "vault.activity"
        case .transferRequest:   type = "TRANSFER_REQUEST"
        }
        if FeedEvent.connectionActivityTypes.contains(type) { return true }
        if FeedEvent.connectionLifecycleTypes.contains(type) { return true }
        return false
    }

    private static func eventMatchesQuery(_ event: FeedEvent, _ q: String) -> Bool {
        switch event {
        case .message(let e):
            return e.senderName.lowercased().contains(q) || e.preview.lowercased().contains(q)
        case .connectionRequest(let e):
            return e.requesterName.lowercased().contains(q)
        case .authRequest(let e):
            return e.serviceName.lowercased().contains(q) || e.actionType.lowercased().contains(q)
        case .vaultActivity(let e):
            return e.description.lowercased().contains(q) || e.activityType.rawValue.lowercased().contains(q)
        case .transferRequest(let e):
            return e.senderName.lowercased().contains(q)
        }
    }

    // MARK: - Vault event load (unchanged from the legacy path)

    func loadFromVault() async {
        guard let client = feedClient else { return }
        do {
            let response = try await client.listFeed(status: nil, limit: 50)
            allEvents = response.events.compactMap { convertVaultEvent($0) }
        } catch {
            #if DEBUG
            print("[FeedViewModel] Vault load failed, falling back to mock: \(error)")
            #endif
            allEvents = FeedEvent.mockFeed()
        }
    }

    private func convertVaultEvent(_ vaultEvent: VaultFeedEvent) -> FeedEvent? {
        let timestamp = Date(timeIntervalSince1970: vaultEvent.createdAt / 1000)
        let isRead = vaultEvent.readAt != nil

        switch vaultEvent.eventType {
        case "message.received", "message.sent":
            return .message(MessageEvent(
                id: vaultEvent.eventId,
                senderId: vaultEvent.sourceId ?? "",
                senderName: vaultEvent.metadata?["sender_name"] ?? vaultEvent.title,
                senderAvatarUrl: vaultEvent.metadata?["avatar_url"],
                preview: vaultEvent.message ?? "",
                timestamp: timestamp,
                isRead: isRead,
                connectionId: vaultEvent.sourceId ?? ""
            ))
        case "connection.request":
            return .connectionRequest(ConnectionRequestEvent(
                id: vaultEvent.eventId,
                requesterId: vaultEvent.sourceId ?? "",
                requesterName: vaultEvent.metadata?["requester_name"] ?? vaultEvent.title,
                requesterAvatarUrl: vaultEvent.metadata?["avatar_url"],
                timestamp: timestamp,
                isRead: isRead,
                status: vaultEvent.actionedAt != nil ? .accepted : .pending
            ))
        case "auth.request":
            return .authRequest(AuthRequestEvent(
                id: vaultEvent.eventId,
                serviceName: vaultEvent.metadata?["service_name"] ?? vaultEvent.title,
                serviceIcon: vaultEvent.metadata?["service_icon"],
                actionType: vaultEvent.actionType ?? "Authentication",
                timestamp: timestamp,
                isRead: isRead,
                status: vaultEvent.actionedAt != nil ? .approved : .pending
            ))
        default:
            return .vaultActivity(VaultActivityEvent(
                id: vaultEvent.eventId,
                activityType: mapActivityType(vaultEvent.eventType),
                description: vaultEvent.message ?? vaultEvent.title,
                timestamp: timestamp,
                isRead: isRead
            ))
        }
    }

    private func mapActivityType(_ eventType: String) -> VaultActivityEvent.VaultActivityType {
        switch eventType {
        case "vault.started":       return .vaultStarted
        case "vault.stopped":       return .vaultStopped
        case "backup.created":      return .backupCreated
        case "backup.restored":     return .backupRestored
        case "credential.added":    return .credentialAdded
        case "keys.refreshed":      return .keysRefreshed
        case "agent.connected":     return .agentConnected
        case "agent.disconnected":  return .agentDisconnected
        case "device.paired":       return .devicePaired
        case "device.revoked":      return .deviceRevoked
        case "handler.registered":  return .handlerRegistered
        case "handler.removed":     return .handlerRemoved
        case "transfer.initiated":  return .transferInitiated
        case "transfer.completed":  return .transferCompleted
        default:                    return .vaultStarted
        }
    }

    // MARK: - Refresh

    func refresh() async { await loadEvents() }

    func startPeriodicRefresh() {
        stopPeriodicRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func stopPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Search

    func searchEvents(query: String) {
        searchQuery = query
        rebuildDisplayItems()
    }

    // MARK: - Mutations (per-event)

    func archiveEvent(eventId: String) {
        guard let client = feedClient else {
            allEvents.removeAll { $0.id == eventId }
            rebuildDisplayItems()
            return
        }
        Task {
            do {
                try await client.archiveEvent(eventId: eventId)
                allEvents.removeAll { $0.id == eventId }
                rebuildDisplayItems()
            } catch {
                actionError = "Failed to archive event: \(error.localizedDescription)"
            }
        }
    }

    func deleteEvent(eventId: String) {
        guard let client = feedClient else {
            allEvents.removeAll { $0.id == eventId }
            rebuildDisplayItems()
            return
        }
        Task {
            do {
                try await client.deleteEvent(eventId: eventId)
                allEvents.removeAll { $0.id == eventId }
                rebuildDisplayItems()
            } catch {
                actionError = "Failed to delete event: \(error.localizedDescription)"
            }
        }
    }

    func markAllAsRead() {
        let unreadIds = allEvents.filter { !$0.isRead }.map { $0.id }
        guard !unreadIds.isEmpty else { return }
        markLocallyRead(unreadIds)
        rebuildDisplayItems()
        if let client = feedClient {
            Task { try? await client.markMultipleRead(eventIds: unreadIds) }
        }
    }

    func markAsRead(_ event: FeedEvent) {
        markLocallyRead([event.id])
        rebuildDisplayItems()
    }

    private func markLocallyRead(_ ids: [String]) {
        let s = Set(ids)
        for i in allEvents.indices where s.contains(allEvents[i].id) {
            switch allEvents[i] {
            case .message(var e):           e.isRead = true; allEvents[i] = .message(e)
            case .connectionRequest(var e): e.isRead = true; allEvents[i] = .connectionRequest(e)
            case .authRequest(var e):       e.isRead = true; allEvents[i] = .authRequest(e)
            case .vaultActivity(var e):     e.isRead = true; allEvents[i] = .vaultActivity(e)
            case .transferRequest(var e):   e.isRead = true; allEvents[i] = .transferRequest(e)
            }
        }
    }

    var unreadCount: Int { allEvents.filter { !$0.isRead }.count }

    // MARK: - Connection actions

    func acceptConnection(requestId: String) async {
        await runConnectionAction("accept", requestId: requestId) { handler in
            try await handler.submitAndAwait(.acceptConnection(requestId: requestId))
        }
    }

    func declineConnection(requestId: String) async {
        await runConnectionAction("decline", requestId: requestId) { handler in
            try await handler.submitAndAwait(.declineConnection(requestId: requestId))
        }
    }

    func approveAuth(requestId: String) async {
        await runConnectionAction("approve auth", requestId: requestId) { handler in
            try await handler.submitAndAwait(.approveAuth(requestId: requestId))
        }
    }

    func denyAuth(requestId: String) async {
        await runConnectionAction("deny auth", requestId: requestId) { handler in
            try await handler.submitAndAwait(.denyAuth(requestId: requestId))
        }
    }

    private func runConnectionAction(
        _ label: String,
        requestId: String,
        _ body: (VaultResponseHandler) async throws -> VaultEventResponse
    ) async {
        guard let handler = vaultResponseHandler else {
            actionError = "Not connected to vault"
            return
        }
        isProcessingAction = true
        actionError = nil
        do {
            let response = try await body(handler)
            if response.isSuccess {
                removeEvent(withRequestId: requestId)
            } else {
                actionError = response.error ?? "Failed to \(label) request"
            }
        } catch {
            actionError = "Failed to \(label) request: \(error.localizedDescription)"
        }
        isProcessingAction = false
    }

    private func removeEvent(withRequestId requestId: String) {
        allEvents.removeAll { event in
            switch event {
            case .connectionRequest(let e): return e.id == requestId
            case .authRequest(let e):       return e.id == requestId
            default:                         return false
            }
        }
        rebuildDisplayItems()
    }
}
