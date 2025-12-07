import Foundation
import BackgroundTasks
import UIKit

/// Manages background refresh tasks for vault synchronization
///
/// Background tasks handled:
/// - Periodic vault status sync
/// - Transaction key replenishment check
/// - Credential rotation verification
final class VaultBackgroundRefresh {

    // MARK: - Task Identifiers

    static let syncTaskIdentifier = "com.vettid.vault.sync"
    static let keyCheckTaskIdentifier = "com.vettid.vault.keycheck"

    // MARK: - Shared Instance

    static let shared = VaultBackgroundRefresh()

    // MARK: - Dependencies

    private let credentialStore = CredentialStore()
    private let apiClient = APIClient()

    // MARK: - Configuration

    private let minKeyThreshold = 5  // Warn when keys fall below this
    private let syncInterval: TimeInterval = 3600  // 1 hour

    private init() {}

    // MARK: - Registration

    /// Register background tasks with the system
    /// Call this from AppDelegate didFinishLaunchingWithOptions
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.syncTaskIdentifier,
            using: nil
        ) { task in
            self.handleSyncTask(task as! BGAppRefreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.keyCheckTaskIdentifier,
            using: nil
        ) { task in
            self.handleKeyCheckTask(task as! BGAppRefreshTask)
        }
    }

    /// Schedule background sync task
    func scheduleSyncTask() {
        let request = BGAppRefreshTaskRequest(identifier: Self.syncTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: syncInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule sync task: \(error)")
        }
    }

    /// Schedule key check task
    func scheduleKeyCheckTask() {
        let request = BGAppRefreshTaskRequest(identifier: Self.keyCheckTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: syncInterval * 2)  // Less frequent

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule key check task: \(error)")
        }
    }

    // MARK: - Task Handlers

    private func handleSyncTask(_ task: BGAppRefreshTask) {
        // Schedule next refresh
        scheduleSyncTask()

        let syncTask = Task {
            await performSync()
        }

        task.expirationHandler = {
            syncTask.cancel()
        }

        Task {
            await syncTask.value
            task.setTaskCompleted(success: true)
        }
    }

    private func handleKeyCheckTask(_ task: BGAppRefreshTask) {
        // Schedule next check
        scheduleKeyCheckTask()

        let checkTask = Task {
            await checkTransactionKeys()
        }

        task.expirationHandler = {
            checkTask.cancel()
        }

        Task {
            await checkTask.value
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - Sync Operations

    /// Perform background vault sync
    private func performSync() async {
        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                return
            }

            // In production, this would call the API to sync vault status
            // For now, just update last sync timestamp

            // Check if credential rotation is needed
            await checkCredentialRotation()

            // Post notification for UI update
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .vaultSyncCompleted,
                    object: nil,
                    userInfo: ["userGuid": credential.userGuid]
                )
            }

        } catch {
            print("Background sync failed: \(error)")
        }
    }

    /// Check if transaction keys need replenishment
    private func checkTransactionKeys() async {
        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                return
            }

            let unusedCount = credential.unusedKeyCount

            if unusedCount < minKeyThreshold {
                // Post notification to warn user
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .transactionKeysLow,
                        object: nil,
                        userInfo: [
                            "remainingKeys": unusedCount,
                            "userGuid": credential.userGuid
                        ]
                    )
                }

                // In production, could trigger automatic key replenishment
                // await replenishKeys()
            }

        } catch {
            print("Key check failed: \(error)")
        }
    }

    /// Check if credential needs rotation
    private func checkCredentialRotation() async {
        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                return
            }

            // Check if credential is too old (e.g., 30 days without auth)
            let daysSinceUse = Calendar.current.dateComponents(
                [.day],
                from: credential.lastUsedAt,
                to: Date()
            ).day ?? 0

            if daysSinceUse > 30 {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .credentialRotationNeeded,
                        object: nil,
                        userInfo: ["userGuid": credential.userGuid]
                    )
                }
            }

        } catch {
            print("Credential rotation check failed: \(error)")
        }
    }

    // MARK: - Manual Operations

    /// Manually trigger a sync (for pull-to-refresh)
    func manualSync() async -> SyncResult {
        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                return .failed(reason: "No credential found")
            }

            await performSync()

            return .success(
                unusedKeys: credential.unusedKeyCount,
                lastSync: Date()
            )

        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Request key replenishment from server
    func requestKeyReplenishment() async -> KeyReplenishResult {
        do {
            guard let credential = try credentialStore.retrieveFirst() else {
                return .failed(reason: "No credential found")
            }

            // In production, this would call the API
            // let response = try await apiClient.replenishTransactionKeys(...)

            // For now, just return current state
            return .success(newKeyCount: credential.unusedKeyCount)

        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}

// MARK: - Result Types

enum SyncResult {
    case success(unusedKeys: Int, lastSync: Date)
    case failed(reason: String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

enum KeyReplenishResult {
    case success(newKeyCount: Int)
    case failed(reason: String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let vaultSyncCompleted = Notification.Name("vaultSyncCompleted")
    static let transactionKeysLow = Notification.Name("transactionKeysLow")
    static let credentialRotationNeeded = Notification.Name("credentialRotationNeeded")
}

// MARK: - App Lifecycle Integration

extension VaultBackgroundRefresh {

    /// Call when app enters background
    func applicationDidEnterBackground() {
        scheduleSyncTask()
        scheduleKeyCheckTask()
    }

    /// Call when app becomes active
    func applicationDidBecomeActive() {
        // Cancel pending tasks since we're active now
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.syncTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.keyCheckTaskIdentifier)
    }
}
