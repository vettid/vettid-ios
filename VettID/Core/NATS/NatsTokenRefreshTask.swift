import Foundation
import BackgroundTasks
import UIKit

/// Background task for refreshing NATS tokens before expiration
///
/// Tokens are refreshed on a 6-hour interval, ensuring we always have
/// valid credentials when the app becomes active.
final class NatsTokenRefreshTask {

    // MARK: - Constants

    static let identifier = "dev.vettid.nats.refresh"
    static let refreshInterval: TimeInterval = 6 * 3600 // 6 hours

    // MARK: - Shared Instance

    static let shared = NatsTokenRefreshTask()

    // MARK: - Dependencies

    private let credentialStore = NatsCredentialStore()
    private let apiClient = APIClient()

    private init() {}

    // MARK: - Registration

    /// Register the background task with the system
    /// Call this from AppDelegate didFinishLaunchingWithOptions
    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: nil
        ) { task in
            self.handleRefresh(task: task as! BGAppRefreshTask)
        }
    }

    // MARK: - Scheduling

    /// Schedule the next token refresh
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("[NatsTokenRefresh] Scheduled refresh for \(request.earliestBeginDate ?? Date())")
        } catch {
            print("[NatsTokenRefresh] Failed to schedule: \(error)")
        }
    }

    /// Cancel any pending refresh tasks
    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
    }

    // MARK: - Task Handler

    private func handleRefresh(task: BGAppRefreshTask) {
        // Schedule the next refresh first
        schedule()

        let refreshTask = Task {
            await performRefresh()
        }

        task.expirationHandler = {
            refreshTask.cancel()
            task.setTaskCompleted(success: false)
        }

        Task {
            let success = await refreshTask.value
            task.setTaskCompleted(success: success)

            // Post notification for UI update
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .natsTokenRefreshed,
                    object: nil,
                    userInfo: ["success": success]
                )
            }
        }
    }

    // MARK: - Refresh Logic

    /// Perform the token refresh
    /// Returns true if successful, false otherwise
    @discardableResult
    func performRefresh() async -> Bool {
        do {
            // Check if we have credentials that need refresh
            guard let credentials = try credentialStore.getCredentials() else {
                print("[NatsTokenRefresh] No credentials to refresh")
                return true // No credentials means nothing to refresh
            }

            // Only refresh if within refresh window (less than 2 hours remaining)
            // This provides a buffer beyond the shouldRefresh 1-hour check
            let twoHoursFromNow = Date().addingTimeInterval(2 * 3600)
            guard credentials.expiresAt <= twoHoursFromNow else {
                print("[NatsTokenRefresh] Credentials don't need refresh yet")
                return true
            }

            print("[NatsTokenRefresh] Refreshing credentials (expires: \(credentials.expiresAt))")

            // Get auth token from stored credential
            // In production, this would use the stored member JWT or refresh it
            guard let authToken = try await getAuthToken() else {
                print("[NatsTokenRefresh] No auth token available")
                return false
            }

            // Request new NATS token
            let response = try await apiClient.generateNatsToken(
                request: .app(deviceId: getDeviceId()),
                authToken: authToken
            )

            // Save new credentials
            let newCredentials = NatsCredentials(from: response)
            try credentialStore.saveCredentials(newCredentials)

            print("[NatsTokenRefresh] Credentials refreshed (new expiry: \(newCredentials.expiresAt))")
            return true

        } catch {
            print("[NatsTokenRefresh] Refresh failed: \(error)")
            return false
        }
    }

    // MARK: - Manual Refresh

    /// Manually trigger a credential refresh (for foreground use)
    func manualRefresh(authToken: String) async throws -> NatsCredentials {
        let response = try await apiClient.generateNatsToken(
            request: .app(deviceId: getDeviceId()),
            authToken: authToken
        )

        let credentials = NatsCredentials(from: response)
        try credentialStore.saveCredentials(credentials)

        return credentials
    }

    /// Check if credentials need immediate refresh
    func needsRefresh() -> Bool {
        guard let credentials = try? credentialStore.getCredentials() else {
            return false // No credentials to refresh
        }
        return credentials.shouldRefresh
    }

    // MARK: - Private Helpers

    private func getDeviceId() -> String {
        let key = "com.vettid.device_id"
        if let deviceId = UserDefaults.standard.string(forKey: key) {
            return deviceId
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    private func getAuthToken() async throws -> String? {
        // In production, this would:
        // 1. Check for stored member JWT
        // 2. Refresh it if expired using Cognito
        // 3. Return the valid token

        // For now, return nil - the app will need to be active to refresh
        // A full implementation would use stored refresh tokens
        return nil
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let natsTokenRefreshed = Notification.Name("natsTokenRefreshed")
}

// MARK: - App Lifecycle Integration

extension NatsTokenRefreshTask {

    /// Call when app enters background
    func applicationDidEnterBackground() {
        schedule()
    }

    /// Call when app becomes active
    func applicationDidBecomeActive() {
        // Check if we need to refresh credentials immediately
        if needsRefresh() {
            NotificationCenter.default.post(
                name: .natsCredentialsNeedRefresh,
                object: nil
            )
        }
    }

    /// Call when app will terminate
    func applicationWillTerminate() {
        cancel()
    }
}

extension Notification.Name {
    static let natsCredentialsNeedRefresh = Notification.Name("natsCredentialsNeedRefresh")
}
