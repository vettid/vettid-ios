import Foundation
import BackgroundTasks
import UIKit

/// Manages background refresh tasks for vault synchronization
///
/// Background tasks handled:
/// - Vault sync: Credential status, transaction key pool check
/// - NATS token refresh: Refresh credentials before expiry
///
/// Matches Android VaultSyncWorker and NatsTokenRefreshWorker functionality.
final class VaultBackgroundRefresh {

    // MARK: - Task Identifiers (must match Info.plist BGTaskSchedulerPermittedIdentifiers)

    static let vaultSyncTaskId = "dev.vettid.vault-refresh"
    static let natsRefreshTaskId = "dev.vettid.nats-token-refresh"
    static let backupTaskId = "dev.vettid.backup"

    // MARK: - Shared Instance

    static let shared = VaultBackgroundRefresh()

    // MARK: - Dependencies

    private let credentialStore = CredentialStore()
    private let natsCredentialStore = NatsCredentialStore()

    // MARK: - Configuration

    /// Minimum transaction key count before warning (matches Android KEY_POOL_THRESHOLD)
    private let keyPoolThreshold = 5

    /// Vault sync interval (iOS minimum is typically 15+ minutes, but system decides actual timing)
    private let vaultSyncInterval: TimeInterval = 15 * 60  // 15 minutes

    /// NATS token refresh interval (matches Android 6-hour interval)
    private let natsRefreshInterval: TimeInterval = 6 * 3600  // 6 hours

    /// Buffer time before NATS token expiry to trigger refresh (2 hours, matches Android)
    private let tokenRefreshBuffer: TimeInterval = 2 * 3600  // 2 hours

    private init() {}

    // MARK: - Registration

    /// Register background tasks with the system
    /// Call this from AppDelegate application(_:didFinishLaunchingWithOptions:)
    func registerBackgroundTasks() {
        // Register vault sync task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.vaultSyncTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleVaultSyncTask(task as! BGAppRefreshTask)
        }

        // Register NATS token refresh task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.natsRefreshTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleNatsRefreshTask(task as! BGAppRefreshTask)
        }

        #if DEBUG
        print("[VaultBackgroundRefresh] Registered background tasks")
        #endif
    }

    // MARK: - Scheduling

    /// Schedule all background tasks
    /// Call when app enters background or after enrollment
    func scheduleAllTasks() {
        scheduleVaultSyncTask()
        scheduleNatsRefreshTask()
    }

    /// Schedule vault sync task
    func scheduleVaultSyncTask() {
        let request = BGAppRefreshTaskRequest(identifier: Self.vaultSyncTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: vaultSyncInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("[VaultBackgroundRefresh] Scheduled vault sync task for \(vaultSyncInterval/60) minutes from now")
            #endif
        } catch {
            #if DEBUG
            print("[VaultBackgroundRefresh] Failed to schedule vault sync task: \(error)")
            #endif
        }
    }

    /// Schedule NATS token refresh task
    func scheduleNatsRefreshTask() {
        let request = BGAppRefreshTaskRequest(identifier: Self.natsRefreshTaskId)

        // Check when current NATS credentials expire and schedule accordingly
        var scheduledInterval = natsRefreshInterval

        if let credentials = try? natsCredentialStore.getCredentials() {
            let timeUntilRefreshNeeded = credentials.expiresAt.timeIntervalSinceNow - tokenRefreshBuffer
            if timeUntilRefreshNeeded > 0 && timeUntilRefreshNeeded < natsRefreshInterval {
                // Schedule sooner if credentials will expire before next regular check
                scheduledInterval = max(60, timeUntilRefreshNeeded)  // At least 1 minute from now
            }
        }

        request.earliestBeginDate = Date(timeIntervalSinceNow: scheduledInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("[VaultBackgroundRefresh] Scheduled NATS refresh task for \(scheduledInterval/60) minutes from now")
            #endif
        } catch {
            #if DEBUG
            print("[VaultBackgroundRefresh] Failed to schedule NATS refresh task: \(error)")
            #endif
        }
    }

    /// Cancel all scheduled tasks (e.g., on logout)
    func cancelAllTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.vaultSyncTaskId)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.natsRefreshTaskId)

        #if DEBUG
        print("[VaultBackgroundRefresh] Cancelled all background tasks")
        #endif
    }

    // MARK: - Task Handlers

    private func handleVaultSyncTask(_ task: BGAppRefreshTask) {
        #if DEBUG
        print("[VaultBackgroundRefresh] Starting vault sync task")
        #endif

        // Schedule next refresh immediately
        scheduleVaultSyncTask()

        // Create async task for sync work
        let syncTask = Task {
            await performVaultSync()
        }

        // Handle task expiration
        task.expirationHandler = {
            syncTask.cancel()
            #if DEBUG
            print("[VaultBackgroundRefresh] Vault sync task expired")
            #endif
        }

        // Complete task when done
        Task {
            _ = await syncTask.result
            task.setTaskCompleted(success: true)
            #if DEBUG
            print("[VaultBackgroundRefresh] Vault sync task completed")
            #endif
        }
    }

    private func handleNatsRefreshTask(_ task: BGAppRefreshTask) {
        #if DEBUG
        print("[VaultBackgroundRefresh] Starting NATS refresh task")
        #endif

        // Schedule next refresh
        scheduleNatsRefreshTask()

        // Create async task for refresh work
        let refreshTask = Task {
            await performNatsCredentialRefresh()
        }

        // Handle task expiration
        task.expirationHandler = {
            refreshTask.cancel()
            #if DEBUG
            print("[VaultBackgroundRefresh] NATS refresh task expired")
            #endif
        }

        // Complete task when done
        Task {
            _ = await refreshTask.result
            task.setTaskCompleted(success: true)
            #if DEBUG
            print("[VaultBackgroundRefresh] NATS refresh task completed")
            #endif
        }
    }

    // MARK: - Sync Operations

    /// Perform vault sync (matches Android VaultSyncWorker.doWork)
    private func performVaultSync() async {
        // 1. Check if user is enrolled
        guard credentialStore.hasStoredCredential(),
              let credential = try? credentialStore.retrieveFirst() else {
            #if DEBUG
            print("[VaultBackgroundRefresh] No credential stored, skipping sync")
            #endif
            return
        }

        // 2. Check transaction key pool
        let utkCount = credential.unusedKeyCount
        if utkCount < keyPoolThreshold {
            #if DEBUG
            print("[VaultBackgroundRefresh] Transaction keys low: \(utkCount) < \(keyPoolThreshold)")
            #endif

            // Post notification to warn user
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .transactionKeysLow,
                    object: nil,
                    userInfo: [
                        "remainingKeys": utkCount,
                        "userGuid": credential.userGuid
                    ]
                )
            }

            // Request more keys via NATS if connected
            await requestMoreTransactionKeys()
        }

        // 3. Check credential rotation status
        await checkCredentialRotation(for: credential)

        // 4. Post sync completed notification
        await MainActor.run {
            NotificationCenter.default.post(
                name: .vaultSyncCompleted,
                object: nil,
                userInfo: [
                    "userGuid": credential.userGuid,
                    "timestamp": Date()
                ]
            )
        }

        #if DEBUG
        print("[VaultBackgroundRefresh] Vault sync completed. UTK count: \(utkCount)")
        #endif
    }

    /// Request additional transaction keys via NATS CredentialsHandler
    private func requestMoreTransactionKeys() async {
        // This requires NATS connection - will be handled by CredentialsHandler
        // when the user next opens the app or NATS reconnects
        #if DEBUG
        print("[VaultBackgroundRefresh] Would request more UTKs - requires NATS connection")
        #endif

        // Post notification so app can handle when foregrounded
        await MainActor.run {
            NotificationCenter.default.post(
                name: .transactionKeyReplenishmentNeeded,
                object: nil
            )
        }
    }

    /// Check if credential rotation is needed
    private func checkCredentialRotation(for credential: StoredCredential) async {
        // Check if credential is stale (e.g., 30+ days without auth)
        let daysSinceUse = Calendar.current.dateComponents(
            [.day],
            from: credential.lastUsedAt,
            to: Date()
        ).day ?? 0

        if daysSinceUse > 30 {
            #if DEBUG
            print("[VaultBackgroundRefresh] Credential rotation recommended: \(daysSinceUse) days since last use")
            #endif

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .credentialRotationNeeded,
                    object: nil,
                    userInfo: ["userGuid": credential.userGuid]
                )
            }
        }
    }

    /// Perform NATS credential refresh (matches Android NatsTokenRefreshWorker.doWork)
    private func performNatsCredentialRefresh() async {
        // 1. Check if we have NATS credentials
        guard let credentials = try? natsCredentialStore.getCredentials() else {
            #if DEBUG
            print("[VaultBackgroundRefresh] No NATS credentials stored, skipping refresh")
            #endif
            return
        }

        // 2. Check if credentials need refresh (within 2-hour buffer)
        let timeUntilExpiry = credentials.expiresAt.timeIntervalSinceNow
        if timeUntilExpiry > tokenRefreshBuffer {
            #if DEBUG
            print("[VaultBackgroundRefresh] NATS credentials still valid (\(Int(timeUntilExpiry/3600))h remaining), no refresh needed")
            #endif
            return
        }

        #if DEBUG
        print("[VaultBackgroundRefresh] NATS credentials need refresh (\(Int(timeUntilExpiry/60))min remaining)")
        #endif

        // 3. Request refresh via vault handler
        // This requires active NATS connection - post notification for app to handle
        await MainActor.run {
            NotificationCenter.default.post(
                name: .natsCredentialRefreshNeeded,
                object: nil,
                userInfo: [
                    "expiresAt": credentials.expiresAt,
                    "timeRemaining": timeUntilExpiry
                ]
            )
        }

        // Note: Actual refresh happens via CredentialsHandler.refreshCredentials()
        // when the app is foregrounded or NATS reconnects. The vault also proactively
        // pushes new credentials via forApp.credentials.rotate, so this serves as a
        // backup mechanism if the app was offline during the push.
    }

    // MARK: - Manual Operations

    /// Manually trigger a sync (for pull-to-refresh)
    func manualSync() async -> SyncResult {
        guard credentialStore.hasStoredCredential(),
              let credential = try? credentialStore.retrieveFirst() else {
            return .failed(reason: "No credential found")
        }

        await performVaultSync()

        return .success(
            unusedKeys: credential.unusedKeyCount,
            lastSync: Date()
        )
    }

    /// Force immediate NATS credential refresh check
    func forceNatsRefresh() async {
        await performNatsCredentialRefresh()
    }

    /// Check sync status
    func getSyncStatus() -> BackgroundSyncStatus {
        let hasCredential = credentialStore.hasStoredCredential()
        let hasNatsCredentials = (try? natsCredentialStore.hasValidCredentials()) ?? false

        var utkCount = 0
        var natsExpiresAt: Date?

        if let credential = try? credentialStore.retrieveFirst() {
            utkCount = credential.unusedKeyCount
        }

        if let natsCredentials = try? natsCredentialStore.getCredentials() {
            natsExpiresAt = natsCredentials.expiresAt
        }

        return BackgroundSyncStatus(
            hasCredential: hasCredential,
            hasNatsCredentials: hasNatsCredentials,
            transactionKeyCount: utkCount,
            keysNeedReplenishment: utkCount < keyPoolThreshold,
            natsCredentialsExpireAt: natsExpiresAt,
            natsNeedsRefresh: natsExpiresAt.map { $0.timeIntervalSinceNow < tokenRefreshBuffer } ?? false
        )
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

struct BackgroundSyncStatus {
    let hasCredential: Bool
    let hasNatsCredentials: Bool
    let transactionKeyCount: Int
    let keysNeedReplenishment: Bool
    let natsCredentialsExpireAt: Date?
    let natsNeedsRefresh: Bool
}

// MARK: - Notification Names

extension Notification.Name {
    static let vaultSyncCompleted = Notification.Name("dev.vettid.vaultSyncCompleted")
    static let transactionKeysLow = Notification.Name("dev.vettid.transactionKeysLow")
    static let transactionKeyReplenishmentNeeded = Notification.Name("dev.vettid.transactionKeyReplenishmentNeeded")
    static let credentialRotationNeeded = Notification.Name("dev.vettid.credentialRotationNeeded")
    static let natsCredentialRefreshNeeded = Notification.Name("dev.vettid.natsCredentialRefreshNeeded")
}

// MARK: - App Lifecycle Integration

extension VaultBackgroundRefresh {

    /// Call when app enters background
    func applicationDidEnterBackground() {
        // Only schedule if user is enrolled
        guard credentialStore.hasStoredCredential() else { return }
        scheduleAllTasks()
    }

    /// Call when app becomes active - check if any sync is needed
    func applicationDidBecomeActive() {
        Task {
            let status = getSyncStatus()

            // Check if NATS credentials need immediate refresh
            if status.natsNeedsRefresh {
                await performNatsCredentialRefresh()
            }

            // Check if transaction keys are low
            if status.keysNeedReplenishment {
                await requestMoreTransactionKeys()
            }
        }
    }

    /// Call after successful enrollment to start background sync
    func onEnrollmentComplete() {
        scheduleAllTasks()
        #if DEBUG
        print("[VaultBackgroundRefresh] Scheduled background tasks after enrollment")
        #endif
    }

    /// Call on logout to stop background sync
    func onLogout() {
        cancelAllTasks()
        #if DEBUG
        print("[VaultBackgroundRefresh] Cancelled background tasks on logout")
        #endif
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension VaultBackgroundRefresh {
    /// Simulate a background task for testing
    /// Call from Xcode debugger: e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.vettid.vault-refresh"]
    func debugPrintScheduledTasks() {
        print("[VaultBackgroundRefresh] Task identifiers:")
        print("  - Vault sync: \(Self.vaultSyncTaskId)")
        print("  - NATS refresh: \(Self.natsRefreshTaskId)")
        print("  - Backup: \(Self.backupTaskId)")

        let status = getSyncStatus()
        print("[VaultBackgroundRefresh] Current status:")
        print("  - Has credential: \(status.hasCredential)")
        print("  - Has NATS credentials: \(status.hasNatsCredentials)")
        print("  - UTK count: \(status.transactionKeyCount)")
        print("  - Keys need replenishment: \(status.keysNeedReplenishment)")
        if let expiry = status.natsCredentialsExpireAt {
            print("  - NATS expires: \(expiry)")
            print("  - NATS needs refresh: \(status.natsNeedsRefresh)")
        }
    }
}
#endif
