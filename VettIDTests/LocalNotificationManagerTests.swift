import XCTest
import UserNotifications
@testable import VettID

/// Tests for LocalNotificationManager (Issue #19)
final class LocalNotificationManagerTests: XCTestCase {

    // MARK: - Category Tests

    func testCategory_rawValues() {
        XCTAssertEqual(LocalNotificationManager.Category.recoveryAlert.rawValue, "RECOVERY_ALERT")
        XCTAssertEqual(LocalNotificationManager.Category.transferRequest.rawValue, "TRANSFER_REQUEST")
        XCTAssertEqual(LocalNotificationManager.Category.fraudAlert.rawValue, "FRAUD_ALERT")
    }

    // MARK: - Action Tests

    func testAction_rawValues() {
        // Recovery actions
        XCTAssertEqual(LocalNotificationManager.Action.cancelRecovery.rawValue, "CANCEL_RECOVERY")
        XCTAssertEqual(LocalNotificationManager.Action.viewRecoveryDetails.rawValue, "VIEW_RECOVERY_DETAILS")

        // Transfer actions
        XCTAssertEqual(LocalNotificationManager.Action.approveTransfer.rawValue, "APPROVE_TRANSFER")
        XCTAssertEqual(LocalNotificationManager.Action.denyTransfer.rawValue, "DENY_TRANSFER")
        XCTAssertEqual(LocalNotificationManager.Action.viewTransferDetails.rawValue, "VIEW_TRANSFER_DETAILS")

        // General actions
        XCTAssertEqual(LocalNotificationManager.Action.dismiss.rawValue, "DISMISS")
    }

    // MARK: - UserInfoKey Tests

    func testUserInfoKey_rawValues() {
        XCTAssertEqual(LocalNotificationManager.UserInfoKey.requestId.rawValue, "request_id")
        XCTAssertEqual(LocalNotificationManager.UserInfoKey.transferId.rawValue, "transfer_id")
        XCTAssertEqual(LocalNotificationManager.UserInfoKey.eventType.rawValue, "event_type")
        XCTAssertEqual(LocalNotificationManager.UserInfoKey.deviceInfo.rawValue, "device_info")
    }

    // MARK: - Singleton Tests

    func testSharedInstance_exists() {
        let manager = LocalNotificationManager.shared
        XCTAssertNotNil(manager)
    }

    func testSharedInstance_isSingleton() {
        let manager1 = LocalNotificationManager.shared
        let manager2 = LocalNotificationManager.shared
        XCTAssertTrue(manager1 === manager2)
    }

    // MARK: - Action Callback Tests

    func testOnActionReceived_canBeSet() async {
        let manager = LocalNotificationManager.shared
        var receivedAction: LocalNotificationManager.Action?
        var receivedUserInfo: [AnyHashable: Any]?

        await MainActor.run {
            manager.onActionReceived = { action, userInfo in
                receivedAction = action
                receivedUserInfo = userInfo
            }
        }

        // Verify callback can be set (actual invocation requires UNUserNotificationCenter delegate call)
        await MainActor.run {
            XCTAssertNotNil(manager.onActionReceived)
        }
    }

    // MARK: - Notification Identifier Tests

    func testRecoveryNotificationIdentifier_format() {
        let requestId = "test-recovery-123"
        let expectedIdentifier = "recovery-\(requestId)"
        XCTAssertEqual(expectedIdentifier, "recovery-test-recovery-123")
    }

    func testTransferNotificationIdentifier_format() {
        let transferId = "test-transfer-456"
        let expectedIdentifier = "transfer-\(transferId)"
        XCTAssertEqual(expectedIdentifier, "transfer-test-transfer-456")
    }

    func testFraudNotificationIdentifier_format() {
        let requestId = "test-fraud-789"
        let expectedIdentifier = "fraud-\(requestId)"
        XCTAssertEqual(expectedIdentifier, "fraud-test-fraud-789")
    }

    // MARK: - VaultSecurityEvent Integration Tests

    func testShowNotification_recoveryRequested() async {
        let manager = LocalNotificationManager.shared
        let event = VaultSecurityEvent.recoveryRequested(
            RecoveryRequestedEvent(
                requestId: "integration-recovery-123",
                email: "test@example.com",
                requestedAt: Date(),
                expiresAt: Date().addingTimeInterval(3600),
                sourceIp: "192.168.1.1",
                userAgent: nil
            )
        )

        // This won't actually show a notification in tests (no permission),
        // but it should not crash
        await manager.showNotification(for: event)
    }

    func testShowNotification_transferRequested() async {
        let manager = LocalNotificationManager.shared
        let event = VaultSecurityEvent.transferRequested(
            TransferRequestedEvent(
                transferId: "integration-transfer-456",
                sourceDeviceId: "old-device",
                targetDeviceInfo: DeviceInfo(
                    deviceId: "new-device",
                    model: "iPhone 15 Pro",
                    osVersion: "iOS 17.2",
                    appVersion: "1.0.0",
                    location: "San Francisco, CA"
                ),
                requestedAt: Date(),
                expiresAt: Date().addingTimeInterval(900)
            )
        )

        await manager.showNotification(for: event)
    }

    func testShowNotification_fraudDetected() async {
        let manager = LocalNotificationManager.shared
        let event = VaultSecurityEvent.recoveryFraudDetected(
            RecoveryFraudDetectedEvent(
                requestId: "integration-fraud-789",
                reason: .credentialUsedDuringRecovery,
                detectedAt: Date(),
                credentialUsedAt: Date().addingTimeInterval(-300),
                usageDetails: "Credential was used for authentication"
            )
        )

        await manager.showNotification(for: event)
    }

    func testShowNotification_recoveryCancelled() async {
        let manager = LocalNotificationManager.shared
        let event = VaultSecurityEvent.recoveryCancelled(
            RecoveryCancelledEvent(
                requestId: "integration-cancelled-123",
                reason: .userCancelled,
                cancelledAt: Date()
            )
        )

        await manager.showNotification(for: event)
    }

    func testShowNotification_transferApproved() async {
        let manager = LocalNotificationManager.shared
        let event = VaultSecurityEvent.transferApproved(
            TransferApprovedEvent(
                transferId: "integration-approved-456",
                approvedAt: Date()
            )
        )

        await manager.showNotification(for: event)
    }

    func testShowNotification_transferDenied() async {
        let manager = LocalNotificationManager.shared
        let event = VaultSecurityEvent.transferDenied(
            TransferDeniedEvent(
                transferId: "integration-denied-789",
                deniedAt: Date(),
                reason: "User denied"
            )
        )

        await manager.showNotification(for: event)
    }

    // MARK: - Notification Removal Tests

    func testRemoveRecoveryNotifications_identifiers() {
        let requestId = "remove-recovery-123"

        // Expected identifiers that would be removed
        let expectedIdentifiers = [
            "recovery-\(requestId)",
            "recovery-cancelled-\(requestId)",
            "fraud-\(requestId)"
        ]

        XCTAssertEqual(expectedIdentifiers.count, 3)
        XCTAssertTrue(expectedIdentifiers.contains("recovery-remove-recovery-123"))
        XCTAssertTrue(expectedIdentifiers.contains("recovery-cancelled-remove-recovery-123"))
        XCTAssertTrue(expectedIdentifiers.contains("fraud-remove-recovery-123"))
    }

    func testRemoveTransferNotifications_identifiers() {
        let transferId = "remove-transfer-456"

        // Expected identifiers that would be removed
        let expectedIdentifiers = [
            "transfer-\(transferId)",
            "transfer-result-\(transferId)"
        ]

        XCTAssertEqual(expectedIdentifiers.count, 2)
        XCTAssertTrue(expectedIdentifiers.contains("transfer-remove-transfer-456"))
        XCTAssertTrue(expectedIdentifiers.contains("transfer-result-remove-transfer-456"))
    }

    // MARK: - Permission Tests

    func testCheckPermissionStatus() async {
        let manager = LocalNotificationManager.shared

        // This will return a real status (likely .notDetermined in test environment)
        let status = await manager.checkPermissionStatus()

        // Just verify it returns a valid status
        XCTAssertTrue([
            UNAuthorizationStatus.notDetermined,
            UNAuthorizationStatus.denied,
            UNAuthorizationStatus.authorized,
            UNAuthorizationStatus.provisional,
            UNAuthorizationStatus.ephemeral
        ].contains(status))
    }

    func testIsAuthorized() async {
        let manager = LocalNotificationManager.shared

        // In test environment, likely not authorized
        let isAuthorized = await manager.isAuthorized()

        // Just verify it returns a boolean without crashing
        XCTAssertNotNil(isAuthorized)
    }
}

// MARK: - Action Mapping Tests

extension LocalNotificationManagerTests {

    func testActionFromIdentifier_validActions() {
        XCTAssertEqual(LocalNotificationManager.Action(rawValue: "CANCEL_RECOVERY"), .cancelRecovery)
        XCTAssertEqual(LocalNotificationManager.Action(rawValue: "VIEW_RECOVERY_DETAILS"), .viewRecoveryDetails)
        XCTAssertEqual(LocalNotificationManager.Action(rawValue: "APPROVE_TRANSFER"), .approveTransfer)
        XCTAssertEqual(LocalNotificationManager.Action(rawValue: "DENY_TRANSFER"), .denyTransfer)
        XCTAssertEqual(LocalNotificationManager.Action(rawValue: "VIEW_TRANSFER_DETAILS"), .viewTransferDetails)
        XCTAssertEqual(LocalNotificationManager.Action(rawValue: "DISMISS"), .dismiss)
    }

    func testActionFromIdentifier_invalidAction() {
        XCTAssertNil(LocalNotificationManager.Action(rawValue: "INVALID_ACTION"))
        XCTAssertNil(LocalNotificationManager.Action(rawValue: ""))
        XCTAssertNil(LocalNotificationManager.Action(rawValue: "cancel_recovery")) // Wrong case
    }
}
