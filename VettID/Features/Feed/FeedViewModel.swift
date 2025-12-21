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
    }

    private var allEvents: [FeedEvent] = []
    private var vaultResponseHandler: VaultResponseHandler?

    // MARK: - Configuration

    func configure(with vaultResponseHandler: VaultResponseHandler) {
        self.vaultResponseHandler = vaultResponseHandler
    }

    // MARK: - Load Events

    func loadEvents() async {
        state = .loading

        // Simulate loading delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        // For now, use mock data
        // TODO: Replace with real data from NATS subscriptions and local storage
        allEvents = FeedEvent.mockFeed()

        if allEvents.isEmpty {
            state = .empty
        } else {
            applyFilter()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        await loadEvents()
    }

    // MARK: - Filtering

    func setFilter(_ filter: FeedFilter) {
        self.filter = filter
        applyFilter()
    }

    private func applyFilter() {
        let filtered: [FeedEvent]

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
        }

        if filtered.isEmpty && filter != .all {
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
