import Foundation
import UserNotifications

/// Manages local notifications for security alerts
/// Issue #19: Security alerts for recovery attempts, device transfers, and fraud detection
@MainActor
final class LocalNotificationManager: NSObject {

    // MARK: - Singleton

    static let shared = LocalNotificationManager()

    // MARK: - Notification Categories

    enum Category: String {
        case recoveryAlert = "RECOVERY_ALERT"
        case transferRequest = "TRANSFER_REQUEST"
        case fraudAlert = "FRAUD_ALERT"
    }

    // MARK: - Notification Actions

    enum Action: String {
        // Recovery actions
        case cancelRecovery = "CANCEL_RECOVERY"
        case viewRecoveryDetails = "VIEW_RECOVERY_DETAILS"

        // Transfer actions
        case approveTransfer = "APPROVE_TRANSFER"
        case denyTransfer = "DENY_TRANSFER"
        case viewTransferDetails = "VIEW_TRANSFER_DETAILS"

        // General actions
        case dismiss = "DISMISS"
    }

    // MARK: - User Info Keys

    enum UserInfoKey: String {
        case requestId = "request_id"
        case transferId = "transfer_id"
        case eventType = "event_type"
        case deviceInfo = "device_info"
    }

    // MARK: - Properties

    private let notificationCenter = UNUserNotificationCenter.current()

    /// Callback for when user takes action on a notification
    var onActionReceived: ((Action, [AnyHashable: Any]) -> Void)?

    // MARK: - Initialization

    private override init() {
        super.init()
        notificationCenter.delegate = self
    }

    // MARK: - Permission Management

    /// Request notification permissions from the user
    func requestPermission() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge, .criticalAlert]
            )

            if granted {
                await registerCategories()
            }

            #if DEBUG
            print("[LocalNotificationManager] Permission granted: \(granted)")
            #endif

            return granted
        } catch {
            #if DEBUG
            print("[LocalNotificationManager] Permission request failed: \(error)")
            #endif
            return false
        }
    }

    /// Check current notification authorization status
    func checkPermissionStatus() async -> UNAuthorizationStatus {
        let settings = await notificationCenter.notificationSettings()
        return settings.authorizationStatus
    }

    /// Check if notifications are authorized
    func isAuthorized() async -> Bool {
        let status = await checkPermissionStatus()
        return status == .authorized || status == .provisional
    }

    // MARK: - Category Registration

    /// Register notification categories with their associated actions
    private func registerCategories() async {
        // Recovery Alert Category - critical security notification
        let cancelRecoveryAction = UNNotificationAction(
            identifier: Action.cancelRecovery.rawValue,
            title: "Cancel Recovery",
            options: [.destructive, .authenticationRequired]
        )

        let viewRecoveryAction = UNNotificationAction(
            identifier: Action.viewRecoveryDetails.rawValue,
            title: "View Details",
            options: [.foreground]
        )

        let recoveryCategory = UNNotificationCategory(
            identifier: Category.recoveryAlert.rawValue,
            actions: [cancelRecoveryAction, viewRecoveryAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Security Alert",
            options: [.customDismissAction]
        )

        // Transfer Request Category - requires user approval
        let approveTransferAction = UNNotificationAction(
            identifier: Action.approveTransfer.rawValue,
            title: "Approve",
            options: [.authenticationRequired]
        )

        let denyTransferAction = UNNotificationAction(
            identifier: Action.denyTransfer.rawValue,
            title: "Deny",
            options: [.destructive, .authenticationRequired]
        )

        let viewTransferAction = UNNotificationAction(
            identifier: Action.viewTransferDetails.rawValue,
            title: "View Details",
            options: [.foreground]
        )

        let transferCategory = UNNotificationCategory(
            identifier: Category.transferRequest.rawValue,
            actions: [approveTransferAction, denyTransferAction, viewTransferAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Transfer Request",
            options: [.customDismissAction]
        )

        // Fraud Alert Category - informational, high priority
        let dismissAction = UNNotificationAction(
            identifier: Action.dismiss.rawValue,
            title: "Dismiss",
            options: []
        )

        let viewFraudAction = UNNotificationAction(
            identifier: Action.viewRecoveryDetails.rawValue,
            title: "View Details",
            options: [.foreground]
        )

        let fraudCategory = UNNotificationCategory(
            identifier: Category.fraudAlert.rawValue,
            actions: [viewFraudAction, dismissAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Security Alert",
            options: []
        )

        notificationCenter.setNotificationCategories([
            recoveryCategory,
            transferCategory,
            fraudCategory
        ])

        #if DEBUG
        print("[LocalNotificationManager] Registered notification categories")
        #endif
    }

    // MARK: - Recovery Alerts

    /// Show a notification for a recovery request
    func showRecoveryAlert(
        requestId: String,
        email: String?,
        sourceIp: String?,
        expiresAt: Date?
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Recovery Request"
        content.subtitle = "Someone is attempting to recover your credential"

        var bodyParts: [String] = []
        if let email = email {
            bodyParts.append("Email: \(email)")
        }
        if let sourceIp = sourceIp {
            bodyParts.append("From: \(sourceIp)")
        }
        if let expiresAt = expiresAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: expiresAt, relativeTo: Date())
            bodyParts.append("Expires \(relative)")
        }

        content.body = bodyParts.isEmpty
            ? "If this wasn't you, cancel immediately."
            : bodyParts.joined(separator: "\n")

        content.categoryIdentifier = Category.recoveryAlert.rawValue
        content.sound = .defaultCritical
        content.interruptionLevel = .critical

        content.userInfo = [
            UserInfoKey.requestId.rawValue: requestId,
            UserInfoKey.eventType.rawValue: "recovery_requested"
        ]

        let request = UNNotificationRequest(
            identifier: "recovery-\(requestId)",
            content: content,
            trigger: nil // Deliver immediately
        )

        try await notificationCenter.add(request)

        #if DEBUG
        print("[LocalNotificationManager] Showed recovery alert for request: \(requestId)")
        #endif
    }

    // MARK: - Transfer Alerts

    /// Show a notification for a device transfer request
    func showTransferAlert(
        transferId: String,
        deviceModel: String,
        deviceLocation: String?,
        expiresAt: Date
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = "📱 Device Transfer Request"
        content.subtitle = "A new device wants access to your credential"

        var bodyParts = ["Device: \(deviceModel)"]
        if let location = deviceLocation {
            bodyParts.append("Location: \(location)")
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: expiresAt, relativeTo: Date())
        bodyParts.append("Expires \(relative)")

        content.body = bodyParts.joined(separator: "\n")

        content.categoryIdentifier = Category.transferRequest.rawValue
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive

        content.userInfo = [
            UserInfoKey.transferId.rawValue: transferId,
            UserInfoKey.eventType.rawValue: "transfer_requested",
            UserInfoKey.deviceInfo.rawValue: deviceModel
        ]

        let request = UNNotificationRequest(
            identifier: "transfer-\(transferId)",
            content: content,
            trigger: nil
        )

        try await notificationCenter.add(request)

        #if DEBUG
        print("[LocalNotificationManager] Showed transfer alert for: \(transferId)")
        #endif
    }

    // MARK: - Fraud Alerts

    /// Show a notification for fraud detection
    func showFraudAlert(
        requestId: String,
        reason: String,
        details: String?
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = "🚨 Fraud Detected"
        content.subtitle = "A suspicious recovery attempt was blocked"

        var body = reason
        if let details = details {
            body += "\n\(details)"
        }
        body += "\n\nYour credential remains secure."

        content.body = body
        content.categoryIdentifier = Category.fraudAlert.rawValue
        content.sound = .defaultCritical
        content.interruptionLevel = .critical

        content.userInfo = [
            UserInfoKey.requestId.rawValue: requestId,
            UserInfoKey.eventType.rawValue: "fraud_detected"
        ]

        let request = UNNotificationRequest(
            identifier: "fraud-\(requestId)",
            content: content,
            trigger: nil
        )

        try await notificationCenter.add(request)

        #if DEBUG
        print("[LocalNotificationManager] Showed fraud alert for request: \(requestId)")
        #endif
    }

    // MARK: - Status Notifications

    /// Show notification when recovery is cancelled
    func showRecoveryCancelledAlert(requestId: String, reason: String?) async throws {
        let content = UNMutableNotificationContent()
        content.title = "✅ Recovery Cancelled"
        content.body = reason ?? "The recovery request has been cancelled."
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: "recovery-cancelled-\(requestId)",
            content: content,
            trigger: nil
        )

        try await notificationCenter.add(request)
    }

    /// Show notification when transfer is completed
    func showTransferCompletedAlert(transferId: String, approved: Bool) async throws {
        let content = UNMutableNotificationContent()
        content.title = approved ? "✅ Transfer Approved" : "❌ Transfer Denied"
        content.body = approved
            ? "Your credential has been transferred to the new device."
            : "The transfer request was denied."
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: "transfer-result-\(transferId)",
            content: content,
            trigger: nil
        )

        try await notificationCenter.add(request)
    }

    // MARK: - Notification Management

    /// Remove a specific notification
    func removeNotification(identifier: String) {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Remove all recovery-related notifications for a request
    func removeRecoveryNotifications(requestId: String) {
        let identifiers = [
            "recovery-\(requestId)",
            "recovery-cancelled-\(requestId)",
            "fraud-\(requestId)"
        ]
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Remove all transfer-related notifications
    func removeTransferNotifications(transferId: String) {
        let identifiers = [
            "transfer-\(transferId)",
            "transfer-result-\(transferId)"
        ]
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Clear all security notifications
    func clearAllSecurityNotifications() {
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
    }

    /// Update the app badge count
    func setBadgeCount(_ count: Int) async {
        do {
            try await notificationCenter.setBadgeCount(count)
        } catch {
            #if DEBUG
            print("[LocalNotificationManager] Failed to set badge count: \(error)")
            #endif
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension LocalNotificationManager: UNUserNotificationCenterDelegate {

    /// Handle notification when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show all security alerts even when app is in foreground
        return [.banner, .sound, .badge, .list]
    }

    /// Handle user interaction with notification
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        #if DEBUG
        print("[LocalNotificationManager] Received action: \(actionIdentifier)")
        #endif

        // Map system actions
        let action: Action?
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            // User tapped the notification
            if let eventType = userInfo[UserInfoKey.eventType.rawValue] as? String {
                switch eventType {
                case "recovery_requested":
                    action = .viewRecoveryDetails
                case "transfer_requested":
                    action = .viewTransferDetails
                default:
                    action = nil
                }
            } else {
                action = nil
            }
        case UNNotificationDismissActionIdentifier:
            action = .dismiss
        default:
            action = Action(rawValue: actionIdentifier)
        }

        if let action = action {
            await MainActor.run {
                onActionReceived?(action, userInfo)
            }
        }
    }
}

// MARK: - VaultSecurityEvent Integration

extension LocalNotificationManager {

    /// Show appropriate notification for a vault security event
    func showNotification(for event: VaultSecurityEvent) async {
        do {
            switch event {
            case .recoveryRequested(let e):
                try await showRecoveryAlert(
                    requestId: e.requestId,
                    email: e.email,
                    sourceIp: e.sourceIp,
                    expiresAt: e.expiresAt
                )

            case .recoveryCancelled(let e):
                try await showRecoveryCancelledAlert(
                    requestId: e.requestId,
                    reason: e.reason?.rawValue
                )

            case .recoveryCompleted(let e):
                removeRecoveryNotifications(requestId: e.requestId)

            case .transferRequested(let e):
                try await showTransferAlert(
                    transferId: e.transferId,
                    deviceModel: e.targetDeviceInfo.displayName,
                    deviceLocation: e.targetDeviceInfo.location,
                    expiresAt: e.expiresAt
                )

            case .transferApproved(let e):
                try await showTransferCompletedAlert(transferId: e.transferId, approved: true)

            case .transferDenied(let e):
                try await showTransferCompletedAlert(transferId: e.transferId, approved: false)

            case .transferCompleted(let e):
                removeTransferNotifications(transferId: e.transferId)

            case .transferExpired(let e):
                removeTransferNotifications(transferId: e.transferId)

            case .recoveryFraudDetected(let e):
                try await showFraudAlert(
                    requestId: e.requestId,
                    reason: formatFraudReason(e.reason),
                    details: e.usageDetails
                )
            }
        } catch {
            #if DEBUG
            print("[LocalNotificationManager] Failed to show notification: \(error)")
            #endif
        }
    }

    private func formatFraudReason(_ reason: FraudDetectionReason) -> String {
        switch reason {
        case .credentialUsedDuringRecovery:
            return "Your credential was used while a recovery was pending"
        case .multipleRecoveryAttempts:
            return "Multiple recovery attempts detected from different locations"
        case .suspiciousActivity:
            return "Suspicious activity pattern detected"
        }
    }
}
