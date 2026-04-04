import Foundation
import SwiftUI

// MARK: - Feed View Model

@MainActor
final class FeedViewModel: ObservableObject {

    enum State {
        case loading
        case empty
        case loaded([FeedEvent])
        case error(String)
    }

    @Published var state: State = .loading
    @Published var filter: FeedFilter = .all
    @Published var isProcessingAction = false
    @Published var actionError: String?

    enum FeedFilter: String, CaseIterable {
        case all = "All"
        case messages = "Messages"
        case connections = "Connections"
        case auth = "Auth"
        case activity = "Activity"
        case agents = "Agents"
        case devices = "Devices"
    }

    @Published var searchQuery = ""

    private var allEvents: [FeedEvent] = []
    private var vaultResponseHandler: VaultResponseHandler?
    private var feedClient: FeedClient?
    private var refreshTimer: Timer?

    // MARK: - Configuration

    func configure(with vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    func configure(feedClient: FeedClient) {
        self.feedClient = feedClient
    }

    // MARK: - Load Events

    func loadEvents() async {
        state = .loading

        // Try vault first, fall back to mock data
        if feedClient != nil {
            await loadFromVault()
        } else {
            // Simulate loading delay for mock data
            try? await Task.sleep(nanoseconds: 500_000_000)
            allEvents = FeedEvent.mockFeed()
        }

        if allEvents.isEmpty {
            state = .empty
        } else {
            applyFilter()
        }
    }

    /// Load events from the vault via FeedClient.
    func loadFromVault() async {
        guard let client = feedClient else { return }

        do {
            let response = try await client.listFeed(status: nil, limit: 50)
            // Convert VaultFeedEvents to local FeedEvent models
            allEvents = response.events.compactMap { vaultEvent -> FeedEvent? in
                convertVaultEvent(vaultEvent)
            }
        } catch {
            #if DEBUG
            print("[FeedViewModel] Vault load failed, falling back to mock: \(error)")
            #endif
            allEvents = FeedEvent.mockFeed()
        }
    }

    /// Convert a VaultFeedEvent to the local FeedEvent enum.
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
            // Treat everything else as vault activity
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
        case "vault.started": return .vaultStarted
        case "vault.stopped": return .vaultStopped
        case "backup.created": return .backupCreated
        case "backup.restored": return .backupRestored
        case "credential.added": return .credentialAdded
        case "keys.refreshed": return .keysRefreshed
        case "agent.connected": return .agentConnected
        case "agent.disconnected": return .agentDisconnected
        case "device.paired": return .devicePaired
        case "device.revoked": return .deviceRevoked
        case "handler.registered": return .handlerRegistered
        case "handler.removed": return .handlerRemoved
        case "transfer.initiated": return .transferInitiated
        case "transfer.completed": return .transferCompleted
        default: return .vaultStarted
        }
    }

    // MARK: - Refresh

    func refresh() async {
        await loadEvents()
    }

    /// Start periodic refresh timer (30 seconds).
    func startPeriodicRefresh() {
        stopPeriodicRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    /// Stop periodic refresh timer.
    func stopPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Search

    func searchEvents(query: String) {
        searchQuery = query
        applyFilter()
    }

    // MARK: - Pin / Archive / Delete

    func pinEvent(eventId: String) {
        guard let client = feedClient else { return }
        Task {
            do {
                // Toggle: set priority to high (1) or normal (0)
                let event = allEvents.first { $0.id == eventId }
                let currentPriority = event != nil ? 0 : 0 // Default to normal
                let newPriority = currentPriority == 1 ? 0 : 1
                try await client.setEventPriority(eventId: eventId, priority: newPriority)
                await refresh()
            } catch {
                actionError = "Failed to pin event: \(error.localizedDescription)"
            }
        }
    }

    func archiveEvent(eventId: String) {
        guard let client = feedClient else {
            // For mock data, just remove from list
            allEvents.removeAll { $0.id == eventId }
            applyFilter()
            return
        }
        Task {
            do {
                try await client.archiveEvent(eventId: eventId)
                allEvents.removeAll { $0.id == eventId }
                applyFilter()
            } catch {
                actionError = "Failed to archive event: \(error.localizedDescription)"
            }
        }
    }

    func deleteEvent(eventId: String) {
        guard let client = feedClient else {
            // For mock data, just remove from list
            allEvents.removeAll { $0.id == eventId }
            applyFilter()
            return
        }
        Task {
            do {
                try await client.deleteEvent(eventId: eventId)
                allEvents.removeAll { $0.id == eventId }
                applyFilter()
            } catch {
                actionError = "Failed to delete event: \(error.localizedDescription)"
            }
        }
    }

    func markAllAsRead() {
        let unreadIds = allEvents.filter { !$0.isRead }.map { $0.id }
        guard !unreadIds.isEmpty else { return }

        // Mark locally
        for i in allEvents.indices {
            switch allEvents[i] {
            case .message(var e):
                e.isRead = true
                allEvents[i] = .message(e)
            case .connectionRequest(var e):
                e.isRead = true
                allEvents[i] = .connectionRequest(e)
            case .authRequest(var e):
                e.isRead = true
                allEvents[i] = .authRequest(e)
            case .vaultActivity(var e):
                e.isRead = true
                allEvents[i] = .vaultActivity(e)
            case .transferRequest(var e):
                e.isRead = true
                allEvents[i] = .transferRequest(e)
            }
        }
        applyFilter()

        // Also mark on vault if available
        if let client = feedClient {
            Task {
                try? await client.markMultipleRead(eventIds: unreadIds)
            }
        }
    }

    // MARK: - Filtering

    func setFilter(_ filter: FeedFilter) {
        self.filter = filter
        applyFilter()
    }

    private func applyFilter() {
        var filtered: [FeedEvent]

        switch filter {
        case .all:
            filtered = allEvents
        case .messages:
            filtered = allEvents.filter {
                if case .message = $0 { return true }
                return false
            }
        case .connections:
            filtered = allEvents.filter {
                if case .connectionRequest = $0 { return true }
                return false
            }
        case .auth:
            filtered = allEvents.filter {
                if case .authRequest = $0 { return true }
                return false
            }
        case .activity:
            filtered = allEvents.filter {
                if case .vaultActivity = $0 { return true }
                return false
            }
        case .agents:
            filtered = allEvents.filter {
                if case .vaultActivity(let e) = $0 {
                    return e.activityType == .agentConnected || e.activityType == .agentDisconnected
                }
                return false
            }
        case .devices:
            filtered = allEvents.filter {
                if case .vaultActivity(let e) = $0 {
                    return e.activityType == .devicePaired || e.activityType == .deviceRevoked
                }
                return false
            }
        }

        // Apply search query
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            filtered = filtered.filter { event in
                switch event {
                case .message(let e):
                    return e.senderName.lowercased().contains(query) ||
                           e.preview.lowercased().contains(query)
                case .connectionRequest(let e):
                    return e.requesterName.lowercased().contains(query)
                case .authRequest(let e):
                    return e.serviceName.lowercased().contains(query) ||
                           e.actionType.lowercased().contains(query)
                case .vaultActivity(let e):
                    return e.description.lowercased().contains(query) ||
                           e.activityType.rawValue.lowercased().contains(query)
                case .transferRequest(let e):
                    return e.senderName.lowercased().contains(query)
                }
            }
        }

        if filtered.isEmpty && (filter != .all || !searchQuery.isEmpty) {
            state = .empty
        } else {
            state = .loaded(filtered)
        }
    }

    // MARK: - Mark as Read

    func markAsRead(_ event: FeedEvent) {
        guard let index = allEvents.firstIndex(where: { $0.id == event.id }) else { return }

        switch allEvents[index] {
        case .message(var e):
            e.isRead = true
            allEvents[index] = .message(e)
        case .connectionRequest(var e):
            e.isRead = true
            allEvents[index] = .connectionRequest(e)
        case .authRequest(var e):
            e.isRead = true
            allEvents[index] = .authRequest(e)
        case .vaultActivity(var e):
            e.isRead = true
            allEvents[index] = .vaultActivity(e)
        case .transferRequest(var e):
            e.isRead = true
            allEvents[index] = .transferRequest(e)
        }

        applyFilter()
    }

    // MARK: - Unread Count

    var unreadCount: Int {
        allEvents.filter { !$0.isRead }.count
    }

    // MARK: - Connection Actions

    func acceptConnection(requestId: String) async {
        guard let handler = vaultResponseHandler else {
            actionError = "Not connected to vault"
            return
        }

        isProcessingAction = true
        actionError = nil

        do {
            let event = VaultEventType.acceptConnection(requestId: requestId)
            let response = try await handler.submitAndAwait(event)

            if response.isSuccess {
                // Remove the connection request from feed
                removeEvent(withRequestId: requestId)
            } else {
                actionError = response.error ?? "Failed to accept connection"
            }
        } catch {
            actionError = "Failed to accept connection: \(error.localizedDescription)"
        }

        isProcessingAction = false
    }

    func declineConnection(requestId: String) async {
        guard let handler = vaultResponseHandler else {
            actionError = "Not connected to vault"
            return
        }

        isProcessingAction = true
        actionError = nil

        do {
            let event = VaultEventType.declineConnection(requestId: requestId)
            let response = try await handler.submitAndAwait(event)

            if response.isSuccess {
                // Remove the connection request from feed
                removeEvent(withRequestId: requestId)
            } else {
                actionError = response.error ?? "Failed to decline connection"
            }
        } catch {
            actionError = "Failed to decline connection: \(error.localizedDescription)"
        }

        isProcessingAction = false
    }

    // MARK: - Auth Actions

    func approveAuth(requestId: String) async {
        guard let handler = vaultResponseHandler else {
            actionError = "Not connected to vault"
            return
        }

        isProcessingAction = true
        actionError = nil

        do {
            let event = VaultEventType.approveAuth(requestId: requestId)
            let response = try await handler.submitAndAwait(event)

            if response.isSuccess {
                // Remove the auth request from feed
                removeEvent(withRequestId: requestId)
            } else {
                actionError = response.error ?? "Failed to approve authentication"
            }
        } catch {
            actionError = "Failed to approve authentication: \(error.localizedDescription)"
        }

        isProcessingAction = false
    }

    func denyAuth(requestId: String) async {
        guard let handler = vaultResponseHandler else {
            actionError = "Not connected to vault"
            return
        }

        isProcessingAction = true
        actionError = nil

        do {
            let event = VaultEventType.denyAuth(requestId: requestId)
            let response = try await handler.submitAndAwait(event)

            if response.isSuccess {
                // Remove the auth request from feed
                removeEvent(withRequestId: requestId)
            } else {
                actionError = response.error ?? "Failed to deny authentication"
            }
        } catch {
            actionError = "Failed to deny authentication: \(error.localizedDescription)"
        }

        isProcessingAction = false
    }

    // MARK: - Helper Methods

    private func removeEvent(withRequestId requestId: String) {
        allEvents.removeAll { event in
            switch event {
            case .connectionRequest(let e):
                return e.id == requestId
            case .authRequest(let e):
                return e.id == requestId
            default:
                return false
            }
        }
        applyFilter()
    }
}
