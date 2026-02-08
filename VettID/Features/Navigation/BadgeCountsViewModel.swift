import SwiftUI
import Combine

@MainActor
class BadgeCountsViewModel: ObservableObject {
    @Published var unreadFeedCount: Int = 0
    @Published var pendingConnectionsCount: Int = 0
    @Published var unvotedProposalsCount: Int = 0

    private var proposalsTimer: Timer?

    var totalBadgeCount: Int {
        unreadFeedCount + pendingConnectionsCount + unvotedProposalsCount
    }

    func badgeCount(for item: DrawerItem) -> Int {
        switch item {
        case .feed: return unreadFeedCount
        case .connections: return pendingConnectionsCount
        case .voting: return unvotedProposalsCount
        case .personalData, .secrets, .archive: return 0
        }
    }

    func startObserving() {
        // Poll proposals every 5 minutes
        proposalsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshProposalsCount()
            }
        }

        Task {
            await refreshAll()
        }
    }

    func stopObserving() {
        proposalsTimer?.invalidate()
        proposalsTimer = nil
    }

    func refreshAll() async {
        await refreshFeedCount()
        await refreshConnectionsCount()
        await refreshProposalsCount()
    }

    private func refreshFeedCount() async {
        // Placeholder — will connect to NATS feed subscription
    }

    private func refreshConnectionsCount() async {
        // Placeholder — will connect to NATS connections subscription
    }

    private func refreshProposalsCount() async {
        // Placeholder — will poll proposals endpoint
    }

    func markFeedRead() {
        unreadFeedCount = 0
    }

    func markConnectionsRead() {
        pendingConnectionsCount = 0
    }
}
