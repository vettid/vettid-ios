import Foundation

/// Coordinates data synchronization after NATS reconnection.
/// Triggered by NatsConnectionManager when connection is restored.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var syncError: String?

    private let offlineQueueManager = OfflineQueueManager.shared

    // MARK: - Full Sync

    /// Perform a full synchronization: process offline queue, then sync all data types.
    /// Called when NATS connection is restored after being offline.
    func performFullSync() async {
        guard !isSyncing else {
            #if DEBUG
            print("[SyncCoordinator] Sync already in progress, skipping")
            #endif
            return
        }

        isSyncing = true
        syncError = nil

        #if DEBUG
        print("[SyncCoordinator] Starting full sync...")
        #endif

        do {
            // Step 1: Process any queued offline operations
            let processed = await offlineQueueManager.processQueue()
            #if DEBUG
            print("[SyncCoordinator] Processed \(processed) offline queue operations")
            #endif

            // Step 2: Sync secrets from vault
            try await syncSecrets()

            // Step 3: Sync personal data from vault
            try await syncPersonalData()

            // Step 4: Sync feed items
            try await syncFeed()

            lastSyncAt = Date()

            #if DEBUG
            print("[SyncCoordinator] Full sync completed at \(lastSyncAt!)")
            #endif
        } catch {
            syncError = error.localizedDescription
            #if DEBUG
            print("[SyncCoordinator] Sync failed: \(error)")
            #endif
        }

        isSyncing = false
    }

    // MARK: - Individual Sync Operations

    /// Sync secrets with the vault via secrets.sync handler
    func syncSecrets() async throws {
        #if DEBUG
        print("[SyncCoordinator] Syncing secrets...")
        #endif
        // TODO: Implement via OwnerSpaceClient secrets.sync NATS request
        // This will compare local secrets with vault state and reconcile
    }

    /// Sync personal data with the vault via personal-data.sync handler
    func syncPersonalData() async throws {
        #if DEBUG
        print("[SyncCoordinator] Syncing personal data...")
        #endif
        // TODO: Implement via OwnerSpaceClient personal-data.sync NATS request
        // This will compare local personal data items with vault state
    }

    /// Sync feed items with the vault via feed.sync handler
    func syncFeed() async throws {
        #if DEBUG
        print("[SyncCoordinator] Syncing feed...")
        #endif
        // TODO: Implement via OwnerSpaceClient feed.sync NATS request
        // This will fetch new feed items since lastSyncAt
    }

    // MARK: - Status

    /// Whether there are pending offline operations
    var hasPendingOperations: Bool {
        get async {
            await offlineQueueManager.pendingCount > 0
        }
    }

    /// How long since last successful sync
    var timeSinceLastSync: TimeInterval? {
        guard let lastSyncAt else { return nil }
        return Date().timeIntervalSince(lastSyncAt)
    }
}
