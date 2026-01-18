import Foundation
import BackgroundTasks

/// Service that monitors vault security events via NATS and shows notifications
/// Issue #18: Real-time security monitoring with hybrid approach (NATS + BGTask)
@MainActor
final class VaultSecurityService {

    // MARK: - Singleton

    static let shared = VaultSecurityService()

    // MARK: - Properties

    private var ownerSpaceClient: OwnerSpaceClient?
    private let notificationManager = LocalNotificationManager.shared

    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring = false

    /// Pending security events that require user action
    private(set) var pendingRecoveryRequests: [String: RecoveryRequestedEvent] = [:]
    private(set) var pendingTransferRequests: [String: TransferRequestedEvent] = [:]

    /// Callback when user takes action from notification
    var onRecoveryAction: ((String, Bool) async -> Void)?  // requestId, shouldCancel
    var onTransferAction: ((String, Bool) async -> Void)?  // transferId, approved

    // MARK: - BGTask Identifiers

    static let bgTaskIdentifier = "com.vettid.securityCheck"

    // MARK: - Initialization

    private init() {
        setupNotificationCallbacks()
    }

    // MARK: - Configuration

    /// Configure the service with an OwnerSpaceClient
    func configure(with client: OwnerSpaceClient) {
        self.ownerSpaceClient = client
    }

    // MARK: - Monitoring Lifecycle

    /// Start monitoring for security events (call when app enters foreground)
    func startMonitoring() {
        guard !isMonitoring else {
            #if DEBUG
            print("[VaultSecurityService] Already monitoring")
            #endif
            return
        }

        guard let client = ownerSpaceClient else {
            #if DEBUG
            print("[VaultSecurityService] No OwnerSpaceClient configured")
            #endif
            return
        }

        isMonitoring = true

        monitoringTask = Task {
            #if DEBUG
            print("[VaultSecurityService] Starting security event monitoring")
            #endif

            do {
                let eventStream = try await client.subscribeToSecurityEvents()

                for await event in eventStream {
                    guard !Task.isCancelled else { break }
                    await handleSecurityEvent(event)
                }
            } catch {
                #if DEBUG
                print("[VaultSecurityService] Monitoring error: \(error)")
                #endif
            }

            isMonitoring = false
            #if DEBUG
            print("[VaultSecurityService] Monitoring stopped")
            #endif
        }
    }

    /// Stop monitoring (call when app enters background)
    func stopMonitoring() {
        #if DEBUG
        print("[VaultSecurityService] Stopping monitoring")
        #endif

        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
    }

    /// Check if currently monitoring
    var isCurrentlyMonitoring: Bool {
        isMonitoring
    }

    // MARK: - Event Handling

    private func handleSecurityEvent(_ event: VaultSecurityEvent) async {
        #if DEBUG
        print("[VaultSecurityService] Received event: \(event)")
        #endif

        // Track pending events
        trackEvent(event)

        // Show notification
        await notificationManager.showNotification(for: event)

        // Update badge count
        await updateBadgeCount()
    }

    private func trackEvent(_ event: VaultSecurityEvent) {
        switch event {
        case .recoveryRequested(let e):
            pendingRecoveryRequests[e.requestId] = e

        case .recoveryCancelled(let e):
            pendingRecoveryRequests.removeValue(forKey: e.requestId)

        case .recoveryCompleted(let e):
            pendingRecoveryRequests.removeValue(forKey: e.requestId)

        case .transferRequested(let e):
            pendingTransferRequests[e.transferId] = e

        case .transferApproved(let e):
            pendingTransferRequests.removeValue(forKey: e.transferId)

        case .transferDenied(let e):
            pendingTransferRequests.removeValue(forKey: e.transferId)

        case .transferCompleted(let e):
            pendingTransferRequests.removeValue(forKey: e.transferId)

        case .transferExpired(let e):
            pendingTransferRequests.removeValue(forKey: e.transferId)

        case .recoveryFraudDetected(let e):
            // Fraud detection auto-cancels recovery, remove from pending
            pendingRecoveryRequests.removeValue(forKey: e.requestId)
        }
    }

    private func updateBadgeCount() async {
        let count = pendingRecoveryRequests.count + pendingTransferRequests.count
        await notificationManager.setBadgeCount(count)
    }

    // MARK: - Notification Action Handling

    private func setupNotificationCallbacks() {
        notificationManager.onActionReceived = { [weak self] action, userInfo in
            Task { @MainActor in
                await self?.handleNotificationAction(action, userInfo: userInfo)
            }
        }
    }

    private func handleNotificationAction(
        _ action: LocalNotificationManager.Action,
        userInfo: [AnyHashable: Any]
    ) async {
        switch action {
        case .cancelRecovery:
            if let requestId = userInfo[LocalNotificationManager.UserInfoKey.requestId.rawValue] as? String {
                await cancelRecovery(requestId: requestId)
            }

        case .viewRecoveryDetails:
            if let requestId = userInfo[LocalNotificationManager.UserInfoKey.requestId.rawValue] as? String {
                await showRecoveryDetails(requestId: requestId)
            }

        case .approveTransfer:
            if let transferId = userInfo[LocalNotificationManager.UserInfoKey.transferId.rawValue] as? String {
                await approveTransfer(transferId: transferId)
            }

        case .denyTransfer:
            if let transferId = userInfo[LocalNotificationManager.UserInfoKey.transferId.rawValue] as? String {
                await denyTransfer(transferId: transferId)
            }

        case .viewTransferDetails:
            if let transferId = userInfo[LocalNotificationManager.UserInfoKey.transferId.rawValue] as? String {
                await showTransferDetails(transferId: transferId)
            }

        case .dismiss:
            break
        }
    }

    // MARK: - Recovery Actions

    /// Cancel a pending recovery request
    func cancelRecovery(requestId: String) async {
        #if DEBUG
        print("[VaultSecurityService] Cancelling recovery: \(requestId)")
        #endif

        // Notify via callback for actual API call
        await onRecoveryAction?(requestId, true)

        // Remove from pending
        pendingRecoveryRequests.removeValue(forKey: requestId)
        notificationManager.removeRecoveryNotifications(requestId: requestId)
        await updateBadgeCount()
    }

    /// Show details for a recovery request (navigate to UI)
    func showRecoveryDetails(requestId: String) async {
        #if DEBUG
        print("[VaultSecurityService] Show recovery details: \(requestId)")
        #endif

        // This would trigger navigation to a recovery details view
        // For now, just call the callback with shouldCancel = false
        await onRecoveryAction?(requestId, false)
    }

    // MARK: - Transfer Actions

    /// Approve a pending transfer request
    func approveTransfer(transferId: String) async {
        #if DEBUG
        print("[VaultSecurityService] Approving transfer: \(transferId)")
        #endif

        await onTransferAction?(transferId, true)

        pendingTransferRequests.removeValue(forKey: transferId)
        notificationManager.removeTransferNotifications(transferId: transferId)
        await updateBadgeCount()
    }

    /// Deny a pending transfer request
    func denyTransfer(transferId: String) async {
        #if DEBUG
        print("[VaultSecurityService] Denying transfer: \(transferId)")
        #endif

        await onTransferAction?(transferId, false)

        pendingTransferRequests.removeValue(forKey: transferId)
        notificationManager.removeTransferNotifications(transferId: transferId)
        await updateBadgeCount()
    }

    /// Show details for a transfer request (navigate to UI)
    func showTransferDetails(transferId: String) async {
        #if DEBUG
        print("[VaultSecurityService] Show transfer details: \(transferId)")
        #endif

        // This would trigger navigation - handled by UI layer
    }

    // MARK: - Background Task Support

    /// Register BGTask for security checks
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: bgTaskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                await VaultSecurityService.shared.handleBackgroundTask(task as! BGAppRefreshTask)
            }
        }

        #if DEBUG
        print("[VaultSecurityService] Registered background task")
        #endif
    }

    /// Schedule next background check
    func scheduleBackgroundCheck() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("[VaultSecurityService] Scheduled background check")
            #endif
        } catch {
            #if DEBUG
            print("[VaultSecurityService] Failed to schedule background check: \(error)")
            #endif
        }
    }

    /// Handle background task execution
    private func handleBackgroundTask(_ task: BGAppRefreshTask) async {
        #if DEBUG
        print("[VaultSecurityService] Executing background task")
        #endif

        // Schedule next check
        scheduleBackgroundCheck()

        // Set expiration handler
        task.expirationHandler = { [weak self] in
            self?.stopMonitoring()
        }

        // Check for missed events
        await checkForMissedEvents()

        task.setTaskCompleted(success: true)
    }

    /// Check for missed events (called from BGTask or app launch)
    func checkForMissedEvents() async {
        guard let client = ownerSpaceClient else { return }

        #if DEBUG
        print("[VaultSecurityService] Checking for missed events")
        #endif

        // Request status from vault to check for pending security events
        do {
            let requestId = try await client.requestStatus()
            #if DEBUG
            print("[VaultSecurityService] Requested status with id: \(requestId)")
            #endif
            // The response will come through the normal event stream
        } catch {
            #if DEBUG
            print("[VaultSecurityService] Failed to check for missed events: \(error)")
            #endif
        }
    }

    // MARK: - Cleanup

    /// Clear all pending events and notifications
    func clearAll() {
        pendingRecoveryRequests.removeAll()
        pendingTransferRequests.removeAll()
        notificationManager.clearAllSecurityNotifications()

        Task {
            await notificationManager.setBadgeCount(0)
        }
    }
}

// MARK: - Scene Phase Integration

import SwiftUI

extension VaultSecurityService {

    /// Call when app scene phase changes
    func handleScenePhase(_ phase: SwiftUI.ScenePhase) {
        switch phase {
        case .active:
            startMonitoring()
        case .inactive:
            // Keep monitoring during brief inactive states
            break
        case .background:
            stopMonitoring()
            scheduleBackgroundCheck()
        @unknown default:
            break
        }
    }
}
